// The Share Extension links `HermesSharing` alone (no NIO-SSH / sqlite3 graph),
// but the app links the full `HermesKit`. Re-exporting `HermesSharing` here lets
// app-side code reach `PendingShareStore` & friends through a single
// `import HermesKit`, so the extension-vs-app split stays invisible to callers.
@_exported import HermesSharing
