import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

class AuthService {
  /// Sign in with email and password
  Future<User?> signIn(String email, String password) async {
    final response = await supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );
    return response.user;
  }

  /// Sign out
  Future<void> signOut() async {
    await supabase.auth.signOut();
  }

  /// Get current user
  User? getCurrentUser() {
    return supabase.auth.currentUser;
  }

  /// Get current session
  Session? getCurrentSession() {
    return supabase.auth.currentSession;
  }

  /// Sign in with roll number, formats it into `<rollnumber>@nnrg.student`
  Future<User?> signInWithRollNumber(String rollNumber, String password) async {
    final email = '${rollNumber.toLowerCase()}@nnrg.student';
    return await signIn(email, password);
  }
}
