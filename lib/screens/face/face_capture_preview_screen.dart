import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import '../../utils/app_styles.dart';
import '../../widgets/animated_button.dart';
import '../../widgets/fade_slide_y.dart';
import '../../utils/auth_flow_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FaceCapturePreviewScreen extends StatefulWidget {
  const FaceCapturePreviewScreen({super.key});

  @override
  State<FaceCapturePreviewScreen> createState() =>
      _FaceCapturePreviewScreenState();
}

class _FaceCapturePreviewScreenState extends State<FaceCapturePreviewScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  bool _isLoading = false;
  bool _isSuccess = false;
  Uint8List? _croppedPhotoBytes;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _scaleAnimation = Tween<double>(
      begin: 0.92,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _controller.forward();

    _processImage();
  }

  Future<void> _processImage() async {
    await Future.delayed(Duration.zero);
    if (!mounted) return;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is! Map) return;

    final rawBytes = args['photoBytes'] as Uint8List?;
    final faceBbox = args['faceBbox'] as Rect?;
    if (rawBytes == null) return;

    Future(() async {
      final img.Image? decoded = img.decodeJpg(rawBytes);
      if (decoded == null) return;

      debugPrint('[PREVIEW] decoded: ${decoded.width}x${decoded.height}');
      debugPrint('[PREVIEW] faceBbox: $faceBbox');

      // The JPEG from _convertYuvToJpegSync is built pixel-by-pixel from
      // YUV planes in landscape orientation (e.g. 1280x720).
      // ML Kit bbox with sensorOrientation=270 reports coordinates in a
      // virtual portrait space where:
      //   x maps to the Y axis of the landscape image
      //   y maps to the X axis of the landscape image
      // So we need to rotate the JPEG 90° counter-clockwise to get portrait,
      // then use bbox as-is since it is already in portrait space.

      // Rotate 90° counter-clockwise for 270° sensor orientation
      final img.Image rotated = img.copyRotate(decoded, angle: -90);
      debugPrint('[PREVIEW] rotated: ${rotated.width}x${rotated.height}');

      Uint8List croppedBytes;

      if (faceBbox != null && faceBbox.width > 0 && faceBbox.height > 0) {
        // bbox is in portrait space — matches rotated image directly
        // Use generous padding so face fills the circle naturally
        final double padX = faceBbox.width * 0.30;
        final double padY = faceBbox.height * 0.40;

        final int cropX = (faceBbox.left - padX).toInt().clamp(
          0,
          rotated.width - 1,
        );
        final int cropY = (faceBbox.top - padY).toInt().clamp(
          0,
          rotated.height - 1,
        );
        final int cropW = (faceBbox.width + 2 * padX).toInt().clamp(
          1,
          rotated.width - cropX,
        );
        final int cropH = (faceBbox.height + 2 * padY).toInt().clamp(
          1,
          rotated.height - cropY,
        );

        debugPrint('[PREVIEW] crop: x=$cropX y=$cropY w=$cropW h=$cropH');

        final img.Image cropped = img.copyCrop(
          rotated,
          x: cropX,
          y: cropY,
          width: cropW,
          height: cropH,
        );
        croppedBytes = Uint8List.fromList(img.encodeJpg(cropped, quality: 90));
      } else {
        debugPrint('[PREVIEW] No valid bbox — using full rotated image');
        croppedBytes = Uint8List.fromList(img.encodeJpg(rotated, quality: 90));
      }

      if (mounted) {
        setState(() {
          _croppedPhotoBytes = croppedBytes;
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        AuthFlowState.instance.passwordSet = true;
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/register', (route) => false);
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          title: const Text(
            'Preview',
            style: TextStyle(
              color: AppStyles.textDark,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                FadeSlideY(
                  delay: const Duration(milliseconds: 100),
                  child: Text(
                    'Make sure your face is clearly visible and well-lit.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: AppStyles.textDark.withValues(alpha: 0.65),
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                FadeSlideY(
                  delay: const Duration(milliseconds: 200),
                  child: Center(
                    child: ScaleTransition(
                      scale: _scaleAnimation,
                      child: SizedBox(
                        width: 260,
                        height: 260,
                        child: Stack(
                          children: [
                            // Single layer: sharp cropped face fills the full circle
                            ClipOval(
                              child: _croppedPhotoBytes != null
                                  ? Image.memory(
                                      _croppedPhotoBytes!,
                                      width: 260,
                                      height: 260,
                                      fit: BoxFit.cover,
                                    )
                                  : Container(
                                      color: Colors.grey.shade200,
                                      child: const Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                    ),
                            ),
                            // Circle border on top
                            Container(
                              width: 260,
                              height: 260,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppStyles.primaryBlue.withValues(
                                    alpha: 0.5,
                                  ),
                                  width: 4,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.1),
                                    blurRadius: 20,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                FadeSlideY(
                  delay: const Duration(milliseconds: 300),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: AppStyles.primaryBlue,
                        width: 1.5,
                      ),
                    ),
                    child: AnimatedButton(
                      onPressed: () {
                        AuthFlowState.instance.passwordSet = true;
                        Navigator.of(context).pushNamedAndRemoveUntil(
                          '/register',
                          (route) => false,
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        foregroundColor: AppStyles.primaryBlue,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Retake',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppStyles.primaryBlue,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FadeSlideY(
                  delay: const Duration(milliseconds: 400),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: AppStyles.primaryBlue.withValues(alpha: 0.28),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: AnimatedButton(
                      onPressed: () async {
                        if (_isLoading || _isSuccess) return;
                        if (_croppedPhotoBytes == null) return;

                        setState(() => _isLoading = true);

                        try {
                          // Step 1 — get current user
                          final user =
                              Supabase.instance.client.auth.currentUser;
                          if (user == null) {
                            setState(() => _isLoading = false);
                            return;
                          }

                          // Step 2 — upload cropped face photo to storage
                          await Supabase.instance.client.storage
                              .from('face-registrations')
                              .uploadBinary(
                                '${user.id}/registration_${user.id}_preview.jpg',
                                _croppedPhotoBytes!,
                                fileOptions: const FileOptions(
                                  contentType: 'image/jpeg',
                                  upsert: true,
                                ),
                              );

                          // Step 3 — get public URL
                          final photoUrl = Supabase.instance.client.storage
                              .from('face-registrations')
                              .getPublicUrl(
                                '${user.id}/registration_${user.id}_preview.jpg',
                              );

                          // Step 4 — save URL to students table
                          final updateResult = await Supabase.instance.client
                              .from('students')
                              .update({'registration_photo': photoUrl})
                              .eq('id', user.id)
                              .select();

                          debugPrint('[PREVIEW] update result: $updateResult');
                          debugPrint('[PREVIEW] photoUrl: $photoUrl');
                          debugPrint('[PREVIEW] user.id: ${user.id}');

                          if (!context.mounted) return;

                          // Step 5 — show success animation
                          setState(() {
                            _isLoading = false;
                            _isSuccess = true;
                          });

                          await Future.delayed(
                            const Duration(milliseconds: 600),
                          );
                          if (!context.mounted) return;

                          // Step 6 — student is NOT approved yet — teacher must approve
                          AuthFlowState.instance.faceRegistered = false;

                          if (AuthFlowState.instance.isFaceReset) {
                            AuthFlowState.instance.isFaceReset = false;
                            Navigator.of(
                              context,
                            ).pushReplacementNamed('/face_updated_success');
                          } else {
                            Navigator.of(
                              context,
                            ).pushReplacementNamed('/registration_success');
                          }
                        } catch (e) {
                          if (!context.mounted) return;
                          setState(() => _isLoading = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Upload failed: $e'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppStyles.primaryBlue,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: _isLoading
                              ? const SizedBox(
                                  key: ValueKey('loading'),
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : _isSuccess
                              ? const Icon(
                                  Icons.check_rounded,
                                  size: 22,
                                  color: Colors.white,
                                  key: ValueKey('success'),
                                )
                              : Row(
                                  key: const ValueKey('default'),
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    SizedBox(width: 18),
                                    Expanded(
                                      child: Text(
                                        'Save & Verify',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Icon(Icons.arrow_forward_rounded, size: 18),
                                    SizedBox(width: 12),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
