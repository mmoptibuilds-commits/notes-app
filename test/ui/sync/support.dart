import 'package:notes/platform/bootstrap.dart';
import 'package:notes/sync/cloud/cloud_api.dart';
import 'package:notes/sync/cloud/cloud_service.dart';
import 'package:notes/sync/cloud/cloud_sync_engine.dart';

class FakeCloudApi implements CloudApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeCloudService extends CloudService {
  FakeCloudService(
    AppServices services, {
    this.testPhase = CloudPhase.signedOut,
  }) : super(
         repo: services.notes,
         api: FakeCloudApi(),
         sessions: MemoryCloudSessionStore(),
         dataDir: '/tmp/cloud-ui-test',
         deviceName: 'Test device',
         loginLauncher: null,
         unavailable: false,
       );

  CloudPhase testPhase;
  CloudStatus testStatus = const CloudStatus(phase: CloudPhase.signedOut);
  CloudLibraryInfo? remoteLibrary;
  JoinReport testReport = const JoinReport(
    identical: 2,
    onlyHere: 0,
    onlyThere: 0,
    differing: 0,
    missingAttachments: 0,
    folderReferenceErrors: 0,
  );
  bool failSignIn = false;
  int uploads = 0, joins = 0;

  @override
  CloudPhase get phase => testPhase;
  @override
  CloudStatus get status => testStatus.copyWith(phase: testPhase);

  @override
  Map<String, int> localSummary() => {
    'notes': 3,
    'folders': 1,
    'images': 2,
    'bytes': 1536,
  };

  @override
  Future<void> signIn() async {
    if (failSignIn) {
      throw const CloudApiException(CloudErrorKind.unauthorized, 'x');
    }
    testPhase = CloudPhase.signedIn;
    notifyListeners();
  }

  @override
  Future<CloudLibraryInfo> libraryInfo() async {
    final lib = remoteLibrary;
    if (lib == null) {
      throw const CloudApiException(CloudErrorKind.notFound, 'x');
    }
    return lib;
  }

  @override
  Future<VerifiedBackup> createVerifiedBackup() async =>
      const VerifiedBackup('/tmp/cloud-ui-test/backup.notes-export', 3, 1, 2);

  @override
  Future<void> uploadLibrary(
    VerifiedBackup backup, {
    void Function(CloudSyncProgress)? onProgress,
  }) async {
    uploads++;
  }

  @override
  Future<JoinReport> inspectForJoin() async => testReport;

  @override
  Future<void> join(JoinReport report) async {
    joins++;
  }

  @override
  Future<Map<String, Object?>> devices() async => {
    'devices': [
      {'id': 'test-owner-sub', 'name': 'Laptop', 'lastSeen': 'recently'},
    ],
  };

  @override
  Future<void> setEnabled(bool value) async {
    testPhase = value ? CloudPhase.ready : CloudPhase.paused;
    notifyListeners();
  }

  @override
  Future<void> syncNow() async {}

  @override
  Future<void> signOut() async {
    testPhase = CloudPhase.signedOut;
    notifyListeners();
  }
}

extension on CloudStatus {
  CloudStatus copyWith({CloudPhase? phase}) => CloudStatus(
    phase: phase ?? this.phase,
    syncing: syncing,
    lastSyncAt: lastSyncAt,
    lastError: lastError,
    pendingRows: pendingRows,
    uploadProgress: uploadProgress,
    joinProgress: joinProgress,
    needsAttention: needsAttention,
  );
}

AppServices servicesWithCloud({CloudPhase phase = CloudPhase.signedOut}) {
  final base = AppServices.inMemory();
  final cloud = FakeCloudService(base, testPhase: phase)
    ..testStatus = CloudStatus(phase: phase);
  return AppServices(base.db, base.notes, base.settings, '', cloud: cloud);
}
