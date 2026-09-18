# Minification is off for release in this build, so these rules are a starting point
# rather than something load-bearing.

# Keep the service: it is started by name from MainActivity and by the system on restart.
-keep class com.felipetamm.watchbridge.GattServerService { *; }
