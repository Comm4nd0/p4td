package uk.co.paws4thoughtdogs.app

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth: the
// BiometricPrompt it shows is a fragment and needs a FragmentActivity host.
class MainActivity: FlutterFragmentActivity() {
}
