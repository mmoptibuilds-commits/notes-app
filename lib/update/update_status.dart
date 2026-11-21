import 'installer.dart';

/// What the Updates screen shows. Exactly one at a time.
sealed class UpdateStatus {
  const UpdateStatus();
}

class UpdateIdle extends UpdateStatus {
  const UpdateIdle();
}

class UpdateChecking extends UpdateStatus {
  const UpdateChecking();
}

/// A stable release exists and this build is the same or newer.
class UpdateUpToDate extends UpdateStatus {
  const UpdateUpToDate();
}

class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable(this.candidate);
  final UpdateCandidate candidate;
}

/// The repository has no stable release at all (only pre-releases or none).
/// This is NOT "up to date".
class UpdateNoStableRelease extends UpdateStatus {
  const UpdateNoStableRelease();
}

/// A stable release exists but publishes nothing for this platform.
class UpdateNoPlatformRelease extends UpdateStatus {
  const UpdateNoPlatformRelease();
}

class UpdateOffline extends UpdateStatus {
  const UpdateOffline({this.candidate});
  final UpdateCandidate? candidate;
}

class UpdateRateLimited extends UpdateStatus {
  const UpdateRateLimited(this.resetAt);
  final DateTime? resetAt;
}

/// A failure. [candidate] is set when it happened while downloading or
/// installing, so Retry resumes that step instead of re-checking.
class UpdateFailed extends UpdateStatus {
  const UpdateFailed(this.message, {this.candidate});
  final String message;
  final UpdateCandidate? candidate;
}

class UpdateDownloading extends UpdateStatus {
  const UpdateDownloading(this.candidate, this.received, this.total);
  final UpdateCandidate candidate;
  final int received;
  final int total;

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

/// A transfer stopped with a verified scope for its partial bytes. The next
/// download action resumes it when the server supports byte ranges.
class UpdateDownloadPaused extends UpdateStatus {
  const UpdateDownloadPaused(this.candidate, this.received, this.total);
  final UpdateCandidate candidate;
  final int received;
  final int total;
}

/// Downloaded and verified, waiting for the user to confirm. [message] is set
/// when an earlier install attempt failed or was cancelled.
class UpdateReadyToInstall extends UpdateStatus {
  const UpdateReadyToInstall(this.candidate, {this.message});
  final UpdateCandidate candidate;
  final String? message;
}

/// A download or the manifest failed verification and was discarded.
class UpdateVerificationFailed extends UpdateStatus {
  const UpdateVerificationFailed(this.reason);
  final String reason;
}

class UpdateInstalling extends UpdateStatus {
  const UpdateInstalling(this.candidate);
  final UpdateCandidate candidate;
}

/// The operating system has taken over. Never reported as success: the next
/// launch compares versions and says "Updated to X" only when it is true.
class UpdateInstallationHandedToOs extends UpdateStatus {
  const UpdateInstallationHandedToOs(
    this.candidate, {
    required this.willRestart,
  });
  final UpdateCandidate candidate;
  final bool willRestart;
}

/// Installing is not possible here. [candidate] is set when an update was
/// found but cannot be applied, so the screen can still describe it.
class UpdateBlocked extends UpdateStatus {
  const UpdateBlocked(this.block, {this.candidate});
  final UpdateBlock block;
  final UpdateCandidate? candidate;
}
