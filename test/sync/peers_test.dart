import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notes/data/app_database.dart';
import 'package:notes/data/migrations.dart';
import 'package:notes/data/note_repository.dart';
import 'package:notes/sync/peers.dart';

Uint8List key(int fill) => Uint8List.fromList(List.filled(32, fill));

void main() {
  late AppDatabase db;
  late PeerStore store;
  setUp(() {
    db = AppDatabase.open(null);
    store = PeerStore(db, nowMs: () => 5000);
  });
  tearDown(() => db.close());

  test('identity is created once and survives reopening', () async {
    final dir = Directory.systemTemp.createTempSync('notes id test ');
    addTearDown(() => dir.deleteSync(recursive: true));
    final k = Uint8List.fromList(List.filled(32, 9));
    var a = AppDatabase.open('${dir.path}/n.db', key: k);
    final id1 = await DeviceIdentity.loadOrCreate(a);
    a.close();
    a = AppDatabase.open('${dir.path}/n.db', key: k);
    final id2 = await DeviceIdentity.loadOrCreate(a);
    a.close();
    expect(id2.publicKey, id1.publicKey);
    expect(id1.publicKey.length, 32);
    final other = await DeviceIdentity.loadOrCreate(db);
    expect(other.publicKey, isNot(id1.publicKey));
  });

  test('concurrent identity creation keeps the first committed key', () async {
    final dir = Directory.systemTemp.createTempSync('notes identity race ');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/notes.db';
    final first = AppDatabase.open(path);
    final second = AppDatabase.open(path);
    addTearDown(first.close);
    addTearDown(second.close);

    final identities = await Future.wait([
      DeviceIdentity.loadOrCreate(first),
      DeviceIdentity.loadOrCreate(second),
    ]);

    expect(identities.first.publicKey, identities.last.publicKey);
  });

  test('add, refresh by same key, refuse a different key, remove', () {
    final p = store.add(
      id: 'peer1',
      name: 'Phone',
      publicKey: key(1),
      endpoints: ['192.168.1.5:47380'],
    );
    expect(p.name, 'Phone');
    expect(p.sentCursor, 0);
    store.add(
      id: 'peer1',
      name: 'Nothing Phone',
      publicKey: key(1),
      endpoints: ['100.64.0.2:47380'],
    );
    final again = store.get('peer1')!;
    expect(again.name, 'Nothing Phone');
    expect(again.endpoints, ['100.64.0.2:47380', '192.168.1.5:47380']);
    expect(
      () => store.add(id: 'peer1', name: 'X', publicKey: key(2)),
      throwsStateError,
    );
    expect(store.list().length, 1);
    store.remove('peer1');
    expect(store.get('peer1'), isNull);
    store.remove('peer1'); // idempotent
  });

  test('at most five devices including this one', () {
    for (var i = 1; i <= 4; i++) {
      store.add(id: 'p$i', name: 'D$i', publicKey: key(i));
    }
    expect(
      () => store.add(id: 'p5', name: 'D5', publicKey: key(5)),
      throwsA(isA<PairingLimitException>()),
    );
    store.remove('p1');
    store.add(id: 'p5', name: 'D5', publicKey: key(5));
    expect(store.list().length, 4);
  });

  test('rejects bad keys and pairing with itself', () {
    expect(
      () => store.add(id: 'x', name: 'x', publicKey: Uint8List(5)),
      throwsArgumentError,
    );
    expect(
      () => store.add(id: db.deviceId, name: 'me', publicKey: key(1)),
      throwsArgumentError,
    );
  });

  test(
    'cursors only move forward and pending counts rows above the sent cursor',
    () {
      store.add(id: 'p', name: 'P', publicKey: key(1));
      final repo = NoteRepository(db);
      repo.createNote(title: 'a');
      repo.createNote(title: 'b');
      repo.createFolder('F');
      expect(store.pendingFor('p'), 3);
      db.transaction(() => store.advance('p', sent: 2, received: 7));
      expect(store.pendingFor('p'), 1);
      db.transaction(() => store.advance('p', sent: 1, received: 3));
      final p = store.get('p')!;
      expect([p.sentCursor, p.recvCursor], [2, 7]);
      expect(store.pendingFor('missing'), 0);
    },
  );

  test(
    'success and error are recorded; endpoints keep the most recent first',
    () {
      store.add(id: 'p', name: 'P', publicKey: key(1), endpoints: ['a:1']);
      store.noteEndpoint('p', 'b:2');
      store.noteEndpoint('p', 'a:1');
      expect(store.get('p')!.endpoints, ['a:1', 'b:2']);
      store.recordError('p', 'timeout');
      expect(store.get('p')!.lastError, 'timeout');
      store.recordSuccess('p');
      expect(store.get('p')!.lastError, isNull);
      expect(store.get('p')!.lastSyncAt, 5000);
    },
  );

  test(
    'upgrading a version-1 database adds the peers table and keeps notes',
    () {
      final dir = Directory.systemTemp.createTempSync('notes mig test ');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/n.db';
      final v1 = AppDatabase.open(path, schema: migrations.sublist(0, 1));
      final id = NoteRepository(v1).createNote(title: 'old note').id;
      expect(v1.raw.userVersion, 1);
      v1.close();
      final v2 = AppDatabase.open(path);
      expect(v2.raw.userVersion, migrations.length);
      expect(NoteRepository(v2).getNote(id)!.title, 'old note');
      PeerStore(v2).add(id: 'p', name: 'P', publicKey: key(1));
      v2.close();
      expect(File('$path.pre-v${migrations.length}.bak').existsSync(), isTrue);
    },
  );
}
