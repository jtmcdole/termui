import 'local_host_driver_interface.dart';
import 'local_host_driver_stub.dart'
    if (dart.library.io) 'local_host_driver_io.dart'
    as impl;

export 'local_host_driver_interface.dart';

/// Creates the platform [LocalHostDriver] (`IoLocalHostDriver` on `dart:io`
/// outside `FLUTTER_TEST`; stub on Web).
LocalHostDriver createLocalHostDriver() => impl.createPlatformLocalHostDriver();
