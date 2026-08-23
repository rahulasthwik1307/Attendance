import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/supabase_service.dart';
import '../../utils/app_styles.dart';
import '../../utils/network_helper.dart';
import '../../widgets/custom_bottom_nav.dart';
import '../../widgets/fade_slide_y.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with TickerProviderStateMixin {
  static String? _cachedName;
  static String? _cachedRollNumber;
  static String? _cachedDepartment;
  static String? _cachedClassSection;
  static String? _cachedYear;
  static String? _cachedInitials;
  static bool? _cachedFaceApproved;
  static bool? _cachedFaceRegistered;
  static String? _cachedProfilePhotoUrl;

  late AnimationController _borderRotationController;

  String _name = '';
  String _rollNumber = '';
  String _department = '';
  String _classSection = '';
  String _year = '';
  String _initials = '';
  bool _isLoading = true;
  double _attendancePct = 0.0;
  int _attendedClasses = 0;
  int _totalClasses = 0;
  bool _faceApproved = false;
  bool _faceRegistered = false;
  String? _profilePhotoUrl;
  bool _isUploadingPhoto = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _borderRotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    if (_cachedName != null) {
      // Static profile data already loaded — show immediately, no spinner
      _name = _cachedName!;
      _rollNumber = _cachedRollNumber ?? '';
      _department = _cachedDepartment ?? '';
      _classSection = _cachedClassSection ?? '';
      _year = _cachedYear ?? '';
      _initials = _cachedInitials ?? '';
      _faceApproved = _cachedFaceApproved ?? false;
      _faceRegistered = _cachedFaceRegistered ?? false;
      _profilePhotoUrl = _cachedProfilePhotoUrl;
      _isLoading = false;
      _refreshAttendanceOnly();
    } else {
      _fetchProfile();
    }
  }

  // Refreshes ONLY the dynamic attendance summary — static fields stay untouched
  Future<void> _refreshAttendanceOnly() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;
      final studentData = await supabase
          .from('students')
          .select('class_id')
          .eq('id', user.id)
          .maybeSingle();
      if (studentData == null) return;
      final classId = studentData['class_id'];

      final sessionsResp = await supabase
          .from('attendance_sessions')
          .select('id')
          .eq('class_id', classId)
          .eq('status', 'finalized');
      final sessionIds = (sessionsResp as List).map((s) => s['id'] as String).toList();

      int attended = 0, total = 0;
      if (sessionIds.isNotEmpty) {
        final attendanceResp = await supabase
            .from('period_attendance')
            .select('status')
            .eq('student_id', user.id)
            .inFilter('session_id', sessionIds)
            .inFilter('status', ['present', 'absent']);
        total = (attendanceResp as List).length;
        attended = attendanceResp.where((r) => r['status'] == 'present').length;
      }
      final pct = total > 0 ? attended / total : 0.0;
      if (mounted) {
        setState(() {
          _attendancePct = pct;
          _attendedClasses = attended;
          _totalClasses = total;
        });
      }
    } catch (e) {
      debugPrint('[PROFILE] attendance refresh error (non-fatal): $e');
      // Silently keep showing last known attendance — no error UI for a background sync
    }
  }

  Future<void> _fetchProfile() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      final results = await Future.wait([
        supabase
            .from('students')
            .select(
              'roll_number, year, class_id, is_approved, face_registered, classes(name, section, department_id)',
            )
            .eq('id', user.id)
            .maybeSingle(),
        supabase
            .from('users')
            .select('full_name, profile_photo_url')
            .eq('id', user.id)
            .maybeSingle(),
      ]);

      final studentData = results[0];
      final userData = results[1];

      if (studentData == null || userData == null) return;

      final fullName = userData['full_name'] as String? ?? '';
      final String? profilePhotoUrl = userData['profile_photo_url'] as String?;
      final rollNumber = studentData['roll_number'] as String? ?? '';
      final year = studentData['year'] as String? ?? '';
      final faceRegistered = studentData['face_registered'] as bool? ?? false;
      final faceApproved = studentData['is_approved'] as bool? ?? false;
      final classData = studentData['classes'] as Map<String, dynamic>?;
      final className = classData?['name'] as String? ?? '';
      final section = classData?['section'] as String? ?? '';
      final departmentId = classData?['department_id'] as String?;

      String departmentName = '';
      if (departmentId != null) {
        final deptData = await supabase
            .from('departments')
            .select('name')
            .eq('id', departmentId)
            .maybeSingle();
        departmentName = deptData?['name'] as String? ?? '';
      }

      final nameParts = fullName.trim().split(' ');
      final initials = nameParts.length >= 2
          ? '${nameParts.first[0]}${nameParts.last[0]}'.toUpperCase()
          : fullName.isNotEmpty
          ? fullName[0].toUpperCase()
          : '?';

      final sessionsResp = await supabase
          .from('attendance_sessions')
          .select('id')
          .eq('class_id', studentData['class_id'])
          .eq('status', 'finalized');

      final sessionIds = (sessionsResp as List)
          .map((s) => s['id'] as String)
          .toList();

      int attended = 0;
      int total = 0;

      if (sessionIds.isNotEmpty) {
        final attendanceResp = await supabase
            .from('period_attendance')
            .select('status')
            .eq('student_id', user.id)
            .inFilter('session_id', sessionIds)
            .inFilter('status', ['present', 'absent']);

        total = (attendanceResp as List).length;
        attended = attendanceResp.where((r) => r['status'] == 'present').length;
      }

      final pct = total > 0 ? attended / total : 0.0;

      if (mounted) {
        setState(() {
          _name = fullName;
          _rollNumber = rollNumber;
          _department = departmentName;
          _classSection = className.isNotEmpty && section.isNotEmpty
              ? '$className - $section'
              : className;
          _year = year;
          _initials = initials;
          _faceRegistered = faceRegistered;
          _faceApproved = faceApproved;
          _attendancePct = pct;
          _attendedClasses = attended;
          _totalClasses = total;
          _profilePhotoUrl = profilePhotoUrl;
          _loadError = null;
          _isLoading = false;
        });

        // Cache static fields for instant display on next visit
        _cachedName = fullName;
        _cachedRollNumber = rollNumber;
        _cachedDepartment = departmentName;
        _cachedClassSection = _classSection;
        _cachedYear = year;
        _cachedInitials = initials;
        _cachedFaceApproved = faceApproved;
        _cachedFaceRegistered = faceRegistered;
        _cachedProfilePhotoUrl = profilePhotoUrl;
      }
    } catch (e) {
      debugPrint('[PROFILE] Error fetching profile: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (_cachedName == null) {
            // No cache exists yet (first-ever load) — surface a retry option
            // instead of leaving a blank screen
            _loadError = NetworkHelper.friendlyMessage(e);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _borderRotationController.dispose();
    super.dispose();
  }

  void _onNavTap(int index) {
    if (index == 0) Navigator.of(context).pushReplacementNamed('/dashboard');
    if (index == 1) Navigator.of(context).pushReplacementNamed('/history');
    if (index == 2) Navigator.of(context).pushReplacementNamed('/settings');
    if (index == 3) return;
  }

  Future<void> _onAvatarTap() async {
    final ImagePicker picker = ImagePicker();

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Profile Photo',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppStyles.textDark),
            ),
            const SizedBox(height: 20),

            // Show current photo preview if exists
            if (_profilePhotoUrl != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 300,
                    minWidth: double.infinity,
                  ),
                  child: Image.network(
                    _profilePhotoUrl!,
                    width: double.infinity,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Container(
                      height: 200,
                      color: Colors.grey.shade100,
                      child: const Icon(Icons.person, size: 60, color: Colors.grey),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            Row(
              children: [
                Expanded(
                  child: _PhotoOptionButton(
                    icon: Icons.camera_alt_rounded,
                    label: 'Camera',
                    onTap: () async {
                      Navigator.pop(ctx);
                      final XFile? file = await picker.pickImage(
                        source: ImageSource.camera,
                        imageQuality: 85,
                      );
                      if (file != null) await _cropAndUpload(file.path);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _PhotoOptionButton(
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    onTap: () async {
                      Navigator.pop(ctx);
                      final XFile? file = await picker.pickImage(
                        source: ImageSource.gallery,
                        imageQuality: 85,
                      );
                      if (file != null) await _cropAndUpload(file.path);
                    },
                  ),
                ),
                if (_profilePhotoUrl != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: _PhotoOptionButton(
                      icon: Icons.delete_outline_rounded,
                      label: 'Remove',
                      isDestructive: true,
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _removePhoto();
                      },
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _cropAndUpload(String imagePath) async {
    final croppedFile = await ImageCropper().cropImage(
      sourcePath: imagePath,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Adjust Photo',
          toolbarColor: AppStyles.primaryBlue,
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
          hideBottomControls: false,
        ),
      ],
    );
    if (croppedFile == null) return;
    if (!mounted) return;
    setState(() => _isUploadingPhoto = true);
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;
      final bytes = await croppedFile.readAsBytes();
      final filePath = '${user.id}/avatar.jpg';
      await supabase.storage
          .from('avatars')
          .uploadBinary(
            filePath,
            bytes,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: true,
            ),
          );
      final publicUrl = supabase.storage.from('avatars').getPublicUrl(filePath);
      final cacheBustedUrl =
          '$publicUrl?t=${DateTime.now().millisecondsSinceEpoch}';
      await supabase
          .from('users')
          .update({'profile_photo_url': cacheBustedUrl})
          .eq('id', user.id);
      if (!mounted) return;
      setState(() => _profilePhotoUrl = cacheBustedUrl);
      _cachedProfilePhotoUrl = cacheBustedUrl;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Profile photo updated!'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Upload failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  Future<void> _removePhoto() async {
    setState(() => _isUploadingPhoto = true);
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;
      final filePath = '${user.id}/avatar.jpg';
      await supabase.storage.from('avatars').remove([filePath]);
      await supabase.from('users').update({'profile_photo_url': null}).eq('id', user.id);
      if (!mounted) return;
      setState(() => _profilePhotoUrl = null);
      _cachedProfilePhotoUrl = null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile photo removed.'), backgroundColor: Colors.orange),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to remove photo: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = theme.textTheme.displayLarge?.color ?? AppStyles.textDark;
    final cardColor = theme.cardTheme.color ?? Colors.white;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Dismiss',
          transitionDuration: const Duration(milliseconds: 250),
          pageBuilder: (context, animation, secondaryAnimation) {
            return Dialog(
              backgroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Exit App',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppStyles.textDark,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Are you sure you want to exit?',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppStyles.textGray,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: AppStyles.textGray.withValues(alpha: 0.3),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 12,
                            ),
                          ),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(
                              color: AppStyles.textGray,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () => SystemNavigator.pop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade600,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 12,
                            ),
                            elevation: 0,
                          ),
                          child: const Text(
                            'Exit',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
          transitionBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.85, end: 1.0).animate(
                  CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                ),
                child: child,
              ),
            );
          },
        );
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          title: Text(
            'Profile',
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.bold,
              fontSize: 24,
            ),
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_off_rounded, size: 40, color: Colors.grey.shade400),
                      const SizedBox(height: 12),
                      Text(
                        _loadError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14, color: AppStyles.textGray),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () {
                          setState(() {
                            _isLoading = true;
                            _loadError = null;
                          });
                          _fetchProfile();
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              )
            : SafeArea(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24.0,
                    vertical: 16.0,
                  ),
                  children: [
                    FadeSlideY(
                      delay: const Duration(milliseconds: 100),
                      child: Center(
                        child: GestureDetector(
                          onTap: _onAvatarTap,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              AnimatedBuilder(
                                animation: _borderRotationController,
                                builder: (context, child) {
                                  return Transform.rotate(
                                    angle:
                                        _borderRotationController.value *
                                        2 *
                                        math.pi,
                                    child: Container(
                                      width: 130,
                                      height: 130,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: SweepGradient(
                                          colors: [
                                            AppStyles.primaryBlue,
                                            Colors.transparent,
                                          ],
                                          stops: [0.0, 0.5],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                              Container(
                                width: 120,
                                height: 120,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: theme.primaryColor.withValues(
                                    alpha: 0.12,
                                  ),
                                  border: Border.all(
                                    color: cardColor,
                                    width: 4,
                                  ),
                                ),
                                child: ClipOval(
                                  child: _isUploadingPhoto
                                      ? const Center(
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                          ),
                                        )
                                      : _profilePhotoUrl != null
                                      ? Image.network(
                                          _profilePhotoUrl!,
                                          fit: BoxFit.cover,
                                          width: 120,
                                          height: 120,
                                          errorBuilder: (_, _, _) => Center(
                                            child: Text(
                                              _initials,
                                              style: TextStyle(
                                                fontSize: 36,
                                                fontWeight: FontWeight.w800,
                                                color: theme.primaryColor,
                                                letterSpacing: -1,
                                              ),
                                            ),
                                          ),
                                        )
                                      : Center(
                                          child: Text(
                                            _initials,
                                            style: TextStyle(
                                              fontSize: 36,
                                              fontWeight: FontWeight.w800,
                                              color: theme.primaryColor,
                                              letterSpacing: -1,
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                              Positioned(
                                bottom: 4,
                                right: 4,
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: AppStyles.primaryBlue,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.camera_alt_rounded,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FadeSlideY(
                      delay: const Duration(milliseconds: 200),
                      child: Center(
                        child: Text(
                          _name,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    FadeSlideY(
                      delay: const Duration(milliseconds: 260),
                      child: Center(
                        child: Text(
                          _rollNumber,
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppStyles.textGray,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ── Attendance badge — two-line layout ──
                    FadeSlideY(
                      delay: const Duration(milliseconds: 320),
                      child: Center(
                        child: Builder(
                          builder: (context) {
                            final pct = (_attendancePct * 100).round();
                            final Color badgeColor = pct >= 90
                                ? const Color(0xFF6366F1)
                                : pct >= 75
                                ? AppStyles.successGreen
                                : AppStyles.errorRed;
                            final IconData badgeIcon = pct >= 90
                                ? Icons.star_rounded
                                : pct >= 75
                                ? Icons.trending_up_rounded
                                : Icons.warning_amber_rounded;
                            final String statusLabel = pct >= 90
                                ? 'Excellent'
                                : pct >= 75
                                ? 'Good'
                                : 'Low';

                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: badgeColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: badgeColor.withValues(alpha: 0.3),
                                  width: 1,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        badgeIcon,
                                        size: 15,
                                        color: badgeColor,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '$statusLabel — $pct% Attendance',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: badgeColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '$_attendedClasses / $_totalClasses Classes Attended',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: badgeColor.withValues(alpha: 0.75),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),

                    // ── Reduced from 28 → 16 to bring info card slightly up ──
                    const SizedBox(height: 16),

                    // ── Info card ──
                    FadeSlideY(
                      delay: const Duration(milliseconds: 400),
                      child: Container(
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            _buildInfoRow(
                              Icons.person_outline_rounded,
                              'Student Name',
                              _name,
                              textColor,
                              isDark,
                            ),
                            Divider(
                              height: 1,
                              color: isDark
                                  ? Colors.grey.shade800
                                  : const Color(0xFFE2E8F0),
                            ),
                            _buildInfoRow(
                              Icons.badge_outlined,
                              'Roll Number',
                              _rollNumber,
                              textColor,
                              isDark,
                            ),
                            Divider(
                              height: 1,
                              color: isDark
                                  ? Colors.grey.shade800
                                  : const Color(0xFFE2E8F0),
                            ),
                            _buildInfoRow(
                              Icons.domain_rounded,
                              'Department',
                              _department,
                              textColor,
                              isDark,
                            ),
                            Divider(
                              height: 1,
                              color: isDark
                                  ? Colors.grey.shade800
                                  : const Color(0xFFE2E8F0),
                            ),
                            _buildInfoRow(
                              Icons.class_outlined,
                              'Class & Section',
                              _classSection,
                              textColor,
                              isDark,
                            ),
                            Divider(
                              height: 1,
                              color: isDark
                                  ? Colors.grey.shade800
                                  : const Color(0xFFE2E8F0),
                            ),
                            _buildInfoRow(
                              Icons.school_outlined,
                              'Year',
                              _year,
                              textColor,
                              isDark,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Face registration card ──
                    FadeSlideY(
                      delay: const Duration(milliseconds: 500),
                      child: Builder(
                        builder: (context) {
                          final String faceStatus = !_faceRegistered
                              ? 'Not Registered'
                              : !_faceApproved
                              ? 'Pending Approval'
                              : 'Approved — Active';
                          final Color faceColor = !_faceRegistered
                              ? AppStyles.textGray
                              : !_faceApproved
                              ? AppStyles.amberWarning
                              : AppStyles.successGreen;
                          final IconData faceIcon = !_faceRegistered
                              ? Icons.face_outlined
                              : !_faceApproved
                              ? Icons.hourglass_top_rounded
                              : Icons.face_retouching_natural_rounded;
                          final IconData faceTrailingIcon = !_faceApproved
                              ? Icons.pending_rounded
                              : Icons.verified_rounded;

                          return Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color: faceColor.withValues(
                                alpha: isDark ? 0.15 : 0.08,
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: faceColor.withValues(alpha: 0.25),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: faceColor.withValues(alpha: 0.15),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    faceIcon,
                                    color: faceColor,
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Face Registration',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: AppStyles.textGray,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        faceStatus,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: faceColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: faceColor.withValues(alpha: 0.15),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    faceTrailingIcon,
                                    color: faceColor,
                                    size: 20,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
        bottomNavigationBar: CustomBottomNav(currentIndex: 3, onTap: _onNavTap),
      ),
    );
  }

  Widget _buildInfoRow(
    IconData icon,
    String label,
    String value,
    Color textColor,
    bool isDark,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Icon pinned to top
          Padding(
            padding: const EdgeInsets.only(top: 1.0),
            child: Icon(icon, color: AppStyles.textGray, size: 20),
          ),
          const SizedBox(width: 12),
          // Label — natural width, never wraps
          Padding(
            padding: const EdgeInsets.only(top: 1.5),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppStyles.textGray,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Value — fills remaining space, left-aligned, wraps cleanly
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              softWrap: true,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: textColor,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoOptionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;
  
  const _PhotoOptionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? Colors.red.shade600 : AppStyles.primaryBlue;
    
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: color.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
