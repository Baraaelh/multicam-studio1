import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Remembers that the user finished the welcome guide and accepted the
/// terms. Bump [_version] when the terms change so everyone sees them again.
class OnboardingStore {
  const OnboardingStore();

  static const _version = 1;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/onboarding_accepted_v$_version');
  }

  Future<bool> isAccepted() async {
    try {
      return await (await _file()).exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> accept() async {
    try {
      await (await _file()).writeAsString(DateTime.now().toIso8601String());
    } catch (_) {
      // Not fatal: the guide just shows again on the next launch.
    }
  }
}
