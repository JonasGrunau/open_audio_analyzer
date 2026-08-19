// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'tokens.dart';

/// Converts between grid cells and pixels.
///
/// The one place in the app that knows how big a cell is. It lives in the
/// design system rather than in the app because the Phase 6 remote display
/// renders the same [GridRect]s on a tablet, and a second implementation of
/// this arithmetic is a guarantee that the two eventually disagree about where
/// a module goes.
///
/// The grid has no outer margin of its own: cell 0 starts at pixel 0 and the
/// last column ends exactly at [size].width. Padding around the canvas is the
/// caller's business, and keeping it out of here is what makes the arithmetic
/// invertible — a rect converted to pixels and back is the rect you started
/// with, which is what the drag preview depends on.
@immutable
class GridGeometry {
  const GridGeometry({required this.size, this.gap = Space.sm});

  final Size size;

  /// The gutter between two adjacent modules.
  ///
  /// Deliberately small. With 24 columns there are 23 gutters across the
  /// canvas, so the generous gap that suits two panels — [Space.xl] — would
  /// spend a third of a laptop screen on empty space between meters.
  final double gap;

  /// Distance from one column's left edge to the next.
  ///
  /// The gap is folded into the stride and then subtracted from the width,
  /// which puts the half-gap that would otherwise appear at each end back into
  /// the modules. Without it the first and last columns are narrower than the
  /// rest and a full-width module does not reach the edges.
  double get columnStride => (size.width + gap) / kGridColumns;
  double get rowStride => (size.height + gap) / kGridRows;

  Rect rectFor(GridRect rect) => Rect.fromLTWH(rect.column * columnStride, rect.row * rowStride, rect.columns * columnStride - gap, rect.rows * rowStride - gap);

  /// The cell containing [point], clamped to the canvas.
  ///
  /// Clamped rather than nullable: a click two pixels outside the last column
  /// means the last column, not "nowhere".
  (int column, int row) cellAt(Offset point) => ((point.dx / columnStride).floor().clamp(0, kGridColumns - 1), (point.dy / rowStride).floor().clamp(0, kGridRows - 1));

  /// A pointer movement expressed in whole cells.
  ///
  /// Rounded, not truncated, so a module snaps to the cell the pointer is
  /// nearest rather than the one it has fully crossed into. Truncating here is
  /// what makes a snapping grid feel like it is lagging behind the mouse.
  (int columns, int rows) deltaInCells(Offset delta) => ((delta.dx / columnStride).round(), (delta.dy / rowStride).round());
}
