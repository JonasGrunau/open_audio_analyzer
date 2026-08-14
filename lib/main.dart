// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/bel_app.dart';

void main() {
  runApp(const ProviderScope(child: BelApp()));
}
