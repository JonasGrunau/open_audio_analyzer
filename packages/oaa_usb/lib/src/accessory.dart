// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// A device on the bus worth knowing about.
final class UsbDevice {
  const UsbDevice({
    required this.vendorId,
    required this.productId,
    required this.bus,
    required this.address,
    required this.isAccessory,
  });

  final int vendorId;
  final int productId;
  final int bus;
  final int address;

  /// Already in accessory mode: open it. Otherwise it might be an Android
  /// device that can be asked to become one.
  final bool isAccessory;

  /// Where it is on the bus — stable while it stays plugged in, and new when
  /// it re-enumerates, which is what switching to accessory mode does.
  String get location => '$bus:$address';

  @override
  String toString() =>
      '${vendorId.toRadixString(16).padLeft(4, '0')}:'
      '${productId.toRadixString(16).padLeft(4, '0')} @ $location'
      '${isAccessory ? ' (accessory)' : ''}';
}

/// What an Android device is told the accessory is. The tablet's application
/// matches the first two in `res/xml/accessory_filter.xml`; a tablet without
/// the application shows the description and offers the address.
final class AccessoryIdentity {
  const AccessoryIdentity({
    this.manufacturer = 'Open Audio Analyzer',
    this.model = 'Display',
    this.description = 'Shows this computer\'s meters on the tablet.',
    this.version = '1',
    this.uri = 'https://open-audio-analyzer.com',
    this.serial = '',
  });

  final String manufacturer;
  final String model;
  final String description;
  final String version;
  final String uri;
  final String serial;
}

/// The bus. Every call is cheap enough for the UI thread except opening a
/// link's isolates, which is asynchronous.
abstract final class AccessoryBus {
  /// Whether this build carries the library at all — macOS and Linux. A
  /// platform without it answers false rather than throwing.
  static bool get available {
    if (!(Platform.isMacOS || Platform.isLinux)) return false;
    try {
      return oaaUsbInit() == 0;
    } on Object {
      return false;
    }
  }

  static List<UsbDevice> scan() {
    const capacity = 64;
    final out = calloc<OaaUsbDevice>(capacity);
    try {
      final count = oaaUsbScan(out, capacity);
      if (count <= 0) return const [];
      return [
        for (var i = 0; i < count && i < capacity; i++)
          UsbDevice(
            vendorId: out[i].vendorId,
            productId: out[i].productId,
            bus: out[i].bus,
            address: out[i].address,
            isAccessory: out[i].kind == kindAccessory,
          ),
      ];
    } finally {
      calloc.free(out);
    }
  }

  /// Asks [device] to become an accessory. The protocol version it speaks once
  /// asked, 0 for a device that does not speak it, negative for a USB error.
  ///
  /// Blocks for as long as the device takes to answer three control requests
  /// — a few milliseconds, at most a second per request.
  static int switchToAccessory(
    UsbDevice device, [
    AccessoryIdentity identity = const AccessoryIdentity(),
  ]) {
    final strings = [
      identity.manufacturer,
      identity.model,
      identity.description,
      identity.version,
      identity.uri,
      identity.serial,
    ].map((s) => s.toNativeUtf8(allocator: calloc).cast<Char>()).toList();
    try {
      return oaaUsbSwitch(
        device.bus,
        device.address,
        strings[0],
        strings[1],
        strings[2],
        strings[3],
        strings[4],
        strings[5],
      );
    } finally {
      for (final s in strings) {
        calloc.free(s);
      }
    }
  }

  /// Opens an accessory-mode device as a byte stream, or null.
  static Future<AccessoryLink?> open(UsbDevice device) async {
    final link = oaaUsbOpen(device.bus, device.address);
    if (link == nullptr) return null;
    return AccessoryLink._start(link);
  }
}

/// The two bulk endpoints of an accessory, as a stream in and a sink out.
///
/// **Two isolates, one per direction,** because a bulk transfer blocks its
/// thread until it completes or times out, and the stream in has to be read
/// all the time while the stream out is written only when there is something to
/// say. The reader returns every 200 ms to see whether it has been told to
/// stop; the writer waits on its port. Closing waits for both before the
/// handle is released, so neither is ever inside libusb with a freed link.
final class AccessoryLink {
  AccessoryLink._(this._link, this._stop);

  final Pointer<OaaUsbLink> _link;
  final Pointer<Int32> _stop;
  final StreamController<Uint8List> _input = StreamController();
  SendPort? _writer;
  Isolate? _readerIsolate;
  Isolate? _writerIsolate;
  final ReceivePort _fromReader = ReceivePort();
  final ReceivePort _fromWriter = ReceivePort();
  final Completer<void> _readerExited = Completer();
  final Completer<void> _writerExited = Completer();
  final ReceivePort _readerExit = ReceivePort();
  final ReceivePort _writerExit = ReceivePort();

  final BytesBuilder _pending = BytesBuilder(copy: false);
  bool _shipScheduled = false;
  int _shipped = 0;
  int _acknowledged = 0;
  final Map<int, Completer<void>> _flushes = {};
  bool _closed = false;

  /// Everything the tablet sends. Done when the cable goes.
  Stream<Uint8List> get input => _input.stream;

  bool get isClosed => _closed;

  static Future<AccessoryLink> _start(Pointer<OaaUsbLink> link) async {
    final stop = calloc<Int32>();
    final accessory = AccessoryLink._(link, stop);
    accessory._fromReader.listen(accessory._onRead);
    final writerReady = Completer<SendPort>();
    accessory._fromWriter.listen((message) {
      if (message is SendPort) {
        writerReady.complete(message);
      } else if (message is int) {
        accessory._onWritten(message);
      } else {
        accessory.close();
      }
    });
    accessory._readerExit.listen((_) => accessory._readerExited.complete());
    accessory._writerExit.listen((_) => accessory._writerExited.complete());

    accessory._readerIsolate = await Isolate.spawn(_read, (
      link.address,
      stop.address,
      accessory._fromReader.sendPort,
    ), onExit: accessory._readerExit.sendPort);
    accessory._writerIsolate = await Isolate.spawn(_write, (
      link.address,
      accessory._fromWriter.sendPort,
    ), onExit: accessory._writerExit.sendPort);
    accessory._writer = await writerReady.future;
    accessory._ship();
    return accessory;
  }

  void _onRead(Object? message) {
    if (message is TransferableTypedData) {
      if (!_input.isClosed) _input.add(message.materialize().asUint8List());
    } else {
      close();
    }
  }

  void _onWritten(int sequence) {
    _acknowledged = sequence;
    for (final key in _flushes.keys.where((k) => k <= sequence).toList()) {
      _flushes.remove(key)!.complete();
    }
  }

  /// Queued and sent on the next turn, coalesced with whatever else is added in
  /// this one: a display port writes a frame as several `add`s.
  void add(List<int> bytes) {
    if (_closed) return;
    _pending.add(bytes);
    if (!_shipScheduled) {
      _shipScheduled = true;
      scheduleMicrotask(_ship);
    }
  }

  void _ship() {
    _shipScheduled = false;
    final writer = _writer;
    if (_closed || writer == null || _pending.isEmpty) return;
    final bytes = _pending.takeBytes();
    writer.send((++_shipped, TransferableTypedData.fromList([bytes])));
  }

  /// Completes when everything added so far has gone down the cable.
  Future<void> flush() {
    if (_closed) return Future.error(const SocketException('Cable closed.'));
    _ship();
    if (_acknowledged >= _shipped) return Future.value();
    return (_flushes[_shipped] ??= Completer<void>()).future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stop.value = 1;
    _writer?.send(null);
    for (final flush in _flushes.values) {
      flush.completeError(const SocketException('Cable closed.'));
    }
    _flushes.clear();
    if (!_input.isClosed) unawaited(_input.close());
    await Future.wait([
      if (_readerIsolate != null) _readerExited.future,
      if (_writerIsolate != null) _writerExited.future,
    ]).timeout(const Duration(seconds: 3), onTimeout: () => []);
    _fromReader.close();
    _fromWriter.close();
    _readerExit.close();
    _writerExit.close();
    oaaUsbClose(_link);
    calloc.free(_stop);
  }
}

/// The reader isolate: bulk reads until the stop flag, an error, or the cable.
void _read((int, int, SendPort) args) {
  final (linkAddress, stopAddress, out) = args;
  final link = Pointer<OaaUsbLink>.fromAddress(linkAddress);
  final stop = Pointer<Int32>.fromAddress(stopAddress);
  // A multiple of the bulk packet size and at least AOA's 16 kB, which Android
  // fills in one transfer.
  const capacity = 16384;
  final buffer = calloc<Uint8>(capacity);
  try {
    while (stop.value == 0) {
      final read = oaaUsbRead(link, buffer, capacity, 200);
      if (read < 0) {
        out.send(null);
        return;
      }
      if (read > 0) {
        out.send(
          TransferableTypedData.fromList([
            Uint8List.fromList(buffer.asTypedList(read)),
          ]),
        );
      }
    }
  } finally {
    calloc.free(buffer);
  }
}

/// The writer isolate: one batch at a time, each acknowledged by sequence.
void _write((int, SendPort) args) {
  final (linkAddress, out) = args;
  final link = Pointer<OaaUsbLink>.fromAddress(linkAddress);
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! (int, TransferableTypedData)) {
      inbox.close();
      return;
    }
    final (sequence, data) = message;
    final bytes = data.materialize().asUint8List();
    final native = calloc<Uint8>(bytes.length);
    try {
      native.asTypedList(bytes.length).setAll(0, bytes);
      final written = oaaUsbWrite(link, native, bytes.length, 2000);
      if (written < 0) {
        out.send('failed');
        inbox.close();
        return;
      }
      out.send(sequence);
    } finally {
      calloc.free(native);
    }
  });
}
