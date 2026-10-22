import os

/// App-wide logger. Values are logged as public so failures can be read with
/// `log show --predicate 'subsystem == "com.simplering.app"'`; never log
/// credentials or tokens through it.
public let ringLog = Logger(subsystem: "com.simplering.app", category: "app")
