/// Attempts to centralize Google Maps customizations, however some other files had to be modified, they are marked
/// with the following in-code comment:
/// // MOD imperative map updates

part of '../google_maps_flutter.dart';

abstract class _GoogleMapStateUpdateHandler<U, I, E> {
  _GoogleMapStateUpdateHandler(this._mapController);

  // The max number of expensive updates that can be done within a frame's time per _GoogleMapStateUpdateHandler
  // There are currently 4 (marker, polygon, polyline, circle) implementations of _GoogleMapStateUpdateHandler so the
  // number of expensive operations happening within a frame will be capped at
  // 4 x _MAX_EXPENSIVE_UPDATES_ITEMS_COUNT_PER_FRAME.
  static const int _MAX_EXPENSIVE_UPDATES_ITEMS_COUNT_PER_FRAME = 2;
  static const int _FRAME_DURATION_MILLIS = 16;
  final GoogleMapController _mapController;
  final List<I> _queuedIdsToRemove = <I>[];
  final List<E> _queuedItemsToAdd = <E>[];
  final List<E> _queuedItemsToChange = <E>[];
  // We want this to be an instance class, since there can be multiple child instances of _GoogleMapStateUpdateHandler.
  // If this becomes a performance issue, we can make this global somehow.
  bool _isRunningUpdates = false;

  U _buildIncrementalUpdates(Set<E> oldItems, Set<E> newItems);
  U _buildRACUpdates(Set<I> idsToRemove, Set<E> itemsToAdd, Set<E> itemsToChange) {
    final U updates = _buildIncrementalUpdates(<E>{}, <E>{});
    _getIdsToRemove(updates).addAll(idsToRemove);
    _getItemsToAdd(updates).addAll(itemsToAdd);
    _getItemsToChange(updates).addAll(itemsToChange);
    return updates;
  }

  Set<I> _getIdsToRemove(U updates);
  Set<E> _getItemsToAdd(U updates);
  Set<E> _getItemsToChange(U updates);
  I _getItemId(E item);

  Map<I, E> _getUpdatedItemsMap(
    Map<I, E> initialValue,
    Set<I> idsToRemove,
    Set<E> itemsToAdd,
    Set<E> itemsToChange,
  ) {
    final Map<I, E> updatedItems = <I, E>{};
    for (final MapEntry<I, E> entry in initialValue.entries) {
      if (!idsToRemove.contains(entry.key)) {
        updatedItems[entry.key] = entry.value;
      }
    }
    for (final E marker in itemsToAdd) {
      updatedItems[_getItemId(marker)] = marker;
    }
    for (final E marker in itemsToChange) {
      updatedItems[_getItemId(marker)] = marker;
    }
    return updatedItems;
  }

  @nonVirtual
  Future<void> apply(
    Set<E> oldItems,
    Set<E> newItems, {
    bool realTime = false,
  }) async {
    final U iUpdates = _buildIncrementalUpdates(oldItems, newItems);
    final Set<I> idsToRemove = _getIdsToRemove(iUpdates);
    final Set<E> itemsToAdd = _getItemsToAdd(iUpdates);
    final Set<E> itemsToChange = _getItemsToChange(iUpdates);
    if (oldItems.isEmpty && newItems.isEmpty && idsToRemove.isEmpty && itemsToAdd.isEmpty && itemsToChange.isEmpty) {
      return;
    }
    if (realTime) {
      await _applyIncrementalUpdates(
        _buildRACUpdates(idsToRemove, itemsToAdd, itemsToChange),
        idsToRemove,
        itemsToAdd,
        itemsToChange,
      );
    } else {
      await _queueUpdates(idsToRemove, itemsToAdd, itemsToChange);
    }
  }

  Future<void> _queueUpdates(
    Set<I> idsToRemove,
    Set<E> itemsToAdd,
    Set<E> itemsToChange,
  ) async {
    // Removing any queued add/change ops that will be negated by a remove op right after
    if (idsToRemove.isNotEmpty) {
      bool removeWhereFunc(E item) => idsToRemove.contains(_getItemId(item));
      _queuedItemsToAdd.removeWhere(removeWhereFunc);
      itemsToChange.removeWhere(removeWhereFunc);
    }
    // Removing any queued change ops that will be further changed by a more recent change op right after
    if (itemsToChange.isNotEmpty) {
      final Set<I> idsToChange = itemsToChange.map((E e) => _getItemId(e)).toSet();
      _queuedItemsToChange.removeWhere((E e) => idsToChange.contains(_getItemId(e)));
    }
    _queuedIdsToRemove.addAll(idsToRemove);
    _queuedItemsToAdd.addAll(itemsToAdd);
    _queuedItemsToChange.addAll(itemsToChange);
    if (_isRunningUpdates) {
      return;
    }
    _isRunningUpdates = true;
    try {
      while (_queuedIdsToRemove.isNotEmpty || _queuedItemsToAdd.isNotEmpty || _queuedItemsToChange.isNotEmpty) {
        await _processQueuedUpdates();
      }
    } finally {
      _isRunningUpdates = false;
    }
  }

  Future<void> _processQueuedUpdates() async {
    // Remove operations are not expensive, hence the whole queue is added at once
    final Set<I> idsToRemove = <I>{..._queuedIdsToRemove};
    _queuedIdsToRemove.clear();
    int expensiveOpsCount = 0;
    final Set<E> itemsToAdd = <E>{};
    while (expensiveOpsCount < _MAX_EXPENSIVE_UPDATES_ITEMS_COUNT_PER_FRAME && _queuedItemsToAdd.isNotEmpty) {
      final E itemToAdd = _queuedItemsToAdd.first;
      itemsToAdd.add(itemToAdd);
      _queuedItemsToAdd.remove(itemToAdd);
      expensiveOpsCount++;
    }
    final Set<E> itemsToChange = <E>{};
    while (expensiveOpsCount < _MAX_EXPENSIVE_UPDATES_ITEMS_COUNT_PER_FRAME && _queuedItemsToChange.isNotEmpty) {
      final E itemToChange = _queuedItemsToChange.first;
      itemsToChange.add(itemToChange);
      _queuedItemsToChange.remove(itemToChange);
      expensiveOpsCount++;
    }
    await _applyIncrementalUpdates(
      _buildRACUpdates(idsToRemove, itemsToAdd, itemsToChange),
      idsToRemove,
      itemsToAdd,
      itemsToChange,
    );
    await Future<void>.delayed(const Duration(milliseconds: _FRAME_DURATION_MILLIS));
  }

  Future<void> _applyIncrementalUpdates(
    U updates,
    Set<I> idsToRemove,
    Set<E> itemsToAdd,
    Set<E> itemsToChange,
  );
}

class _GoogleMapStateMarkersUpdateHandler extends _GoogleMapStateUpdateHandler<MarkerUpdates, MarkerId, Marker> {
  _GoogleMapStateMarkersUpdateHandler(super.mapController);

  @override
  MarkerUpdates _buildIncrementalUpdates(Set<Marker> oldItems, Set<Marker> newItems) {
    return MarkerUpdates.from(oldItems, newItems);
  }

  @override
  Set<MarkerId> _getIdsToRemove(MarkerUpdates updates) => updates.markerIdsToRemove;

  @override
  Set<Marker> _getItemsToAdd(MarkerUpdates updates) => updates.markersToAdd;

  @override
  Set<Marker> _getItemsToChange(MarkerUpdates updates) => updates.markersToChange;

  @override
  MarkerId _getItemId(Marker item) => item.markerId;

  @override
  Future<void> _applyIncrementalUpdates(
    MarkerUpdates updates,
    Set<MarkerId> idsToRemove,
    Set<Marker> itemsToAdd,
    Set<Marker> itemsToChange,
  ) async {
    await _mapController._updateMarkers(updates);
    _mapController._googleMapState._markers = _getUpdatedItemsMap(
      _mapController._googleMapState._markers,
      idsToRemove,
      itemsToAdd,
      itemsToChange,
    );
  }
}

class _GoogleMapStatePolylinesUpdateHandler
    extends _GoogleMapStateUpdateHandler<PolylineUpdates, PolylineId, Polyline> {
  _GoogleMapStatePolylinesUpdateHandler(super.mapController);

  @override
  PolylineUpdates _buildIncrementalUpdates(Set<Polyline> oldItems, Set<Polyline> newItems) {
    return PolylineUpdates.from(oldItems, newItems);
  }

  @override
  Set<PolylineId> _getIdsToRemove(PolylineUpdates updates) => updates.polylineIdsToRemove;

  @override
  Set<Polyline> _getItemsToAdd(PolylineUpdates updates) => updates.polylinesToAdd;

  @override
  Set<Polyline> _getItemsToChange(PolylineUpdates updates) => updates.polylinesToChange;

  @override
  PolylineId _getItemId(Polyline item) => item.polylineId;

  @override
  Future<void> _applyIncrementalUpdates(
    PolylineUpdates updates,
    Set<PolylineId> idsToRemove,
    Set<Polyline> itemsToAdd,
    Set<Polyline> itemsToChange,
  ) async {
    await _mapController._updatePolylines(updates);
    _mapController._googleMapState._polylines = _getUpdatedItemsMap(
      _mapController._googleMapState._polylines,
      idsToRemove,
      itemsToAdd,
      itemsToChange,
    );
  }
}

class _GoogleMapStatePolygonsUpdateHandler extends _GoogleMapStateUpdateHandler<PolygonUpdates, PolygonId, Polygon> {
  _GoogleMapStatePolygonsUpdateHandler(super.mapController);

  @override
  PolygonUpdates _buildIncrementalUpdates(Set<Polygon> oldItems, Set<Polygon> newItems) {
    return PolygonUpdates.from(oldItems, newItems);
  }

  @override
  Set<PolygonId> _getIdsToRemove(PolygonUpdates updates) => updates.polygonIdsToRemove;

  @override
  Set<Polygon> _getItemsToAdd(PolygonUpdates updates) => updates.polygonsToAdd;

  @override
  Set<Polygon> _getItemsToChange(PolygonUpdates updates) => updates.polygonsToChange;

  @override
  PolygonId _getItemId(Polygon item) => item.polygonId;

  @override
  Future<void> _applyIncrementalUpdates(
    PolygonUpdates updates,
    Set<PolygonId> idsToRemove,
    Set<Polygon> itemsToAdd,
    Set<Polygon> itemsToChange,
  ) async {
    await _mapController._updatePolygons(updates);
    _mapController._googleMapState._polygons = _getUpdatedItemsMap(
      _mapController._googleMapState._polygons,
      idsToRemove,
      itemsToAdd,
      itemsToChange,
    );
  }
}

class _GoogleMapStateCirclesUpdateHandler extends _GoogleMapStateUpdateHandler<CircleUpdates, CircleId, Circle> {
  _GoogleMapStateCirclesUpdateHandler(super.mapController);

  @override
  CircleUpdates _buildIncrementalUpdates(Set<Circle> oldItems, Set<Circle> newItems) {
    return CircleUpdates.from(oldItems, newItems);
  }

  @override
  Set<CircleId> _getIdsToRemove(CircleUpdates updates) => updates.circleIdsToRemove;

  @override
  Set<Circle> _getItemsToAdd(CircleUpdates updates) => updates.circlesToAdd;

  @override
  Set<Circle> _getItemsToChange(CircleUpdates updates) => updates.circlesToChange;

  @override
  CircleId _getItemId(Circle item) => item.circleId;

  @override
  Future<void> _applyIncrementalUpdates(
    CircleUpdates updates,
    Set<CircleId> idsToRemove,
    Set<Circle> itemsToAdd,
    Set<Circle> itemsToChange,
  ) async {
    await _mapController._updateCircles(updates);
    _mapController._googleMapState._circles = _getUpdatedItemsMap(
      _mapController._googleMapState._circles,
      idsToRemove,
      itemsToAdd,
      itemsToChange,
    );
  }
}

extension _GoogleMapStateExtension on _GoogleMapState {
  MapConfiguration _buildMapConfigurationWithMapType(
    MapType mapType, {
    required bool indoorViewEnabled,
  }) {
    return MapConfiguration(
      compassEnabled: widget.compassEnabled,
      mapToolbarEnabled: widget.mapToolbarEnabled,
      cameraTargetBounds: widget.cameraTargetBounds,
      mapType: mapType,
      minMaxZoomPreference: widget.minMaxZoomPreference,
      rotateGesturesEnabled: widget.rotateGesturesEnabled,
      scrollGesturesEnabled: widget.scrollGesturesEnabled,
      tiltGesturesEnabled: widget.tiltGesturesEnabled,
      trackCameraPosition: widget.onCameraMove != null,
      zoomControlsEnabled: widget.zoomControlsEnabled,
      zoomGesturesEnabled: widget.zoomGesturesEnabled,
      liteModeEnabled: widget.liteModeEnabled,
      myLocationEnabled: widget.myLocationEnabled,
      myLocationButtonEnabled: widget.myLocationButtonEnabled,
      padding: widget.padding,
      indoorViewEnabled: indoorViewEnabled,
      trafficEnabled: widget.trafficEnabled,
      buildingsEnabled: widget.buildingsEnabled,
    );
  }
}

/// Extension on the GoogleMapController object allowing to make map object updates imperatively for:
/// - Map camera
/// - Map type
/// - Markers
/// - Polylines
/// - Polygons
/// - Circles
extension GoogleMapControllerImperativeExtension on GoogleMapController {
  // The following fields were added to the GoogleMapController class to support this extension:
  // late final _GoogleMapStateMarkersUpdateHandler _markersUpdateHandler = _GoogleMapStateMarkersUpdateHandler(this);
  // late final _GoogleMapStatePolylinesUpdateHandler _polylinesUpdateHandler = _GoogleMapStatePolylinesUpdateHandler(this);
  // late final _GoogleMapStatePolygonsUpdateHandler _polygonsUpdateHandler = _GoogleMapStatePolygonsUpdateHandler(this);
  // late final _GoogleMapStateCirclesUpdateHandler _circlesUpdateHandler = _GoogleMapStateCirclesUpdateHandler(this);

  /// Same as moveCamera, except the onCameraMove callback is invoked from this action
  Future<void> moveCameraToPosition(CameraPosition cameraPosition) async {
    await moveCamera(CameraUpdate.newCameraPosition(cameraPosition));
    _googleMapState.widget.onCameraMove?.call(cameraPosition);
  }

  /// Updates the map type used by the GoogleMap widget
  Future<void> updateMapType(
    MapType mapType, {
    required bool indoorViewEnabled,
  }) {
    return _updateMapConfiguration(_googleMapState._buildMapConfigurationWithMapType(
      mapType,
      indoorViewEnabled: indoorViewEnabled,
    ));
  }

  /// Updates a set of markers with a new set of markers.
  /// The set of markers can be a partial list markers.
  Future<void> partiallyUpdateMarkers(
    Set<Marker> oldMarkers,
    Set<Marker> newMarkers, {
    bool realTime = false,
  }) async {
    await _markersUpdateHandler.apply(oldMarkers, newMarkers, realTime: realTime);
  }

  /// Updates a set of polylines with a new set of polylines.
  /// The set of polylines can be a partial list polylines.
  Future<void> partiallyUpdatePolylines(
    Set<Polyline> oldPolylines,
    Set<Polyline> newPolylines, {
    bool realTime = false,
  }) async {
    await _polylinesUpdateHandler.apply(oldPolylines, newPolylines, realTime: realTime);
  }

  /// Updates a set of polygons with a new set of polygons.
  /// The set of polygons can be a partial list polygons.
  Future<void> partiallyUpdatePolygons(
    Set<Polygon> oldPolygons,
    Set<Polygon> newPolygons, {
    bool realTime = false,
  }) async {
    await _polygonsUpdateHandler.apply(oldPolygons, newPolygons, realTime: realTime);
  }

  /// Updates a set of circles with a new set of circles.
  /// The set of circles can be a partial list circles.
  Future<void> partiallyUpdateCircles(
    Set<Circle> oldCircles,
    Set<Circle> newCircles, {
    bool realTime = false,
  }) async {
    await _circlesUpdateHandler.apply(oldCircles, newCircles, realTime: realTime);
  }
}
