import 'package:core_bus/core_bus.dart';

/// The shared event bus for widget book navigation events.
final widgetBookEventBus = EventBus();

/// Published by the Widget Book when the selected page is changed.
const pageChangedEvent = Event<String>.broadcast(name: 'pageChanged');

/// Published by the host application to request a page change in the Widget Book.
const pageSelectedEvent = Event<String>.broadcast(name: 'pageSelected');
