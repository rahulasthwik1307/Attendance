class NetworkHelper {
  /// Returns a safe, human-readable message for any caught exception.
  /// Never exposes raw Supabase/Postgres error text to the user.
  static String friendlyMessage(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('socketexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('network is unreachable') ||
        msg.contains('connection refused') ||
        msg.contains('connection failed') ||
        msg.contains('timeoutexception')) {
      return "You're offline. Please check your internet connection.";
    }
    if (msg.contains('503') ||
        msg.contains('service unavailable') ||
        msg.contains('project is paused')) {
      return 'Unable to connect to the attendance server. Please try again shortly.';
    }
    return 'Something went wrong. Please try again.';
  }
}
