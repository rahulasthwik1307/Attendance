// ─────────────────────────────────────────────────────────────────────────────
// PATCH for lib/screens/auth/sign_in_screen.dart
//
// DO NOT replace the entire file — only find and replace the section
// that currently reads "faceRegData" and handles post-login navigation.
//
// Find this existing block in your sign_in_screen.dart (approximate lines):
//
//   final faceRegData = await supabase
//       .from('face_registrations')
//       .select(...)
//       ...
//   AuthFlowState.instance.faceRegistered = true;
//   Navigator.of(context).pushReplacementNamed('/dashboard');
//
// Replace that entire post-login navigation block with the code below.
// ─────────────────────────────────────────────────────────────────────────────
//
// PASTE THIS inside your _signIn() or equivalent function,
// right after "final user = supabase.auth.currentUser;" succeeds:

/*

// ── Step 1: Check if student has embedding_a (face registered?) ──────────────
final studentData = await supabase
    .from('students')
    .select('embedding_a')
    .eq('id', user!.id)
    .maybeSingle();

final bool hasEmbedding = studentData != null &&
    studentData['embedding_a'] != null;

if (!hasEmbedding) {
  // Face not registered yet → go to registration
  AuthFlowState.instance.faceRegistered = false;
  if (mounted) {
    Navigator.of(context).pushReplacementNamed('/register');
  }
  return;
}

// ── Step 2: Check teacher approval status ────────────────────────────────────
final faceRegData = await supabase
    .from('face_registrations')
    .select('approved')
    .eq('student_id', user.id)
    .maybeSingle();

// Also check is_approved directly from students table as fallback
final approvalData = await supabase
    .from('students')
    .select('is_approved')
    .eq('id', user.id)
    .maybeSingle();

final bool isApproved = (faceRegData != null && faceRegData['approved'] == true) ||
    (approvalData != null && approvalData['is_approved'] == true);

if (!isApproved) {
  // Face registered but not approved → waiting screen
  AuthFlowState.instance.faceRegistered = false;
  if (mounted) {
    Navigator.of(context).pushReplacementNamed('/registration_pending');
    // NOTE: If you don't have a /registration_pending route,
    // use /registration_success which already shows the waiting state,
    // OR navigate to /dashboard — dashboard will block attendance
    // because is_approved is false (Phase 2 handles this).
    // Simplest for now:
    // Navigator.of(context).pushReplacementNamed('/registration_success');
  }
  return;
}

// ── Step 3: Approved — go to dashboard ───────────────────────────────────────
AuthFlowState.instance.faceRegistered = true;
if (mounted) {
  Navigator.of(context).pushReplacementNamed('/dashboard');
}

*/

// ─────────────────────────────────────────────────────────────────────────────
// NOTES:
//
// 1. The '/registration_pending' route — if this route does not exist in
//    main.dart, use '/registration_success' as it shows "Awaiting approval"
//    messaging. Or add a new route pointing to RegistrationSuccessScreen.
//
// 2. The students table query uses '.maybeSingle()' not '.single()' to
//    avoid throwing if the row doesn't exist yet (new accounts).
//
// 3. Do NOT change anything else in sign_in_screen.dart —
//    only replace the post-login navigation block.
// ─────────────────────────────────────────────────────────────────────────────
