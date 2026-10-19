import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wspolne/wspolne.dart' show emailKey;

import '../config.dart';
import '../domain/models.dart';
import '../domain/release.dart';

enum AddMemberResult { added, alreadyMember, notFound }

class JoinException implements Exception {
  const JoinException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Dane sklepu w Firestore (projekt wspólny z Zakupami i Powrotem).
///
/// ```
/// groups/{gid}                     name, ownerId, members[], memberEmails{}, trustedSigners[]
/// groups/{gid}/apps/{appId}        StoreApp (+ latest - zapisuje CI)
/// groups/{gid}/installs/{uid_pkg}  kto ma którą wersję
/// invites/{kod}                    groupId, groupName, createdBy, expiresAt
/// ```
/// Reguły: firebase/firestore.rules
class StoreRepository {
  StoreRepository(this.uid, this.email, {FirebaseFirestore? db}) : db = db ?? FirebaseFirestore.instance;

  final String uid;
  final String email;
  final FirebaseFirestore db;

  CollectionReference<Map<String, dynamic>> get _groups => db.collection('groups');
  CollectionReference<Map<String, dynamic>> _apps(String gid) => _groups.doc(gid).collection('apps');

  // ------------------------------------------------------------------ grupy

  Stream<List<StoreGroup>> watchMyGroups() => _groups
      .where('members', arrayContains: uid)
      .snapshots()
      .map((s) => s.docs.map(StoreGroup.fromDoc).toList()..sort((a, b) => a.name.compareTo(b.name)));

  Stream<StoreGroup?> watchGroup(String gid) =>
      _groups.doc(gid).snapshots().map((d) => d.exists ? StoreGroup.fromDoc(d) : null);

  /// [trustedSigners] - zwykle klucze z istniejących grup, żeby nowa grupa ufała tym samym aplikacjom.
  Future<String> createGroup(String name, {Iterable<String> trustedSigners = const []}) async {
    final ref = await _groups.add({
      'name': name.trim(),
      'ownerId': uid,
      'members': [uid],
      'memberEmails': {uid: emailKey(email)},
      'trustedSigners': trustedSigners.toSet().toList(),
      // Aplikacje przypisuje administrator; autoAdd włącza się tylko wyraźnie (sklep auto tak).
      'autoAdd': false,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  Future<void> renameGroup(String gid, String name) =>
      _groups.doc(gid).update({'name': name.trim(), 'updatedAt': FieldValue.serverTimestamp()});

  Future<void> deleteGroup(String gid) async {
    final apps = await _apps(gid).get();
    final installs = await _groups.doc(gid).collection('installs').get();
    final batch = db.batch();
    for (final d in [...apps.docs, ...installs.docs]) {
      batch.delete(d.reference);
    }
    batch.delete(_groups.doc(gid));
    await batch.commit();
  }

  /// Dopisanie osoby po e-mailu (musi mieć konto - wpis w książce adresowej `emails`).
  Future<AddMemberResult> addMemberByEmail(StoreGroup group, String memberEmail) async {
    final key = emailKey(memberEmail);
    final entry = await db.collection('emails').doc(key).get();
    final memberUid = entry.data()?['uid'] as String?;
    if (!entry.exists || memberUid == null) return AddMemberResult.notFound;
    if (group.members.contains(memberUid)) return AddMemberResult.alreadyMember;
    await _groups.doc(group.id).update({
      'members': FieldValue.arrayUnion([memberUid]),
      FieldPath(['memberEmails', memberUid]): key,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return AddMemberResult.added;
  }

  Future<void> removeMember(String gid, String memberUid) => _groups.doc(gid).update({
        'members': FieldValue.arrayRemove([memberUid]),
        FieldPath(['memberEmails', memberUid]): FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> addTrustedSigner(String gid, String sha256) => _groups.doc(gid).update({
        'trustedSigners': FieldValue.arrayUnion([sha256]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> removeTrustedSigner(String gid, String sha256) => _groups.doc(gid).update({
        'trustedSigners': FieldValue.arrayRemove([sha256]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  // ------------------------------------------------------------------ aplikacje

  Stream<List<StoreApp>> watchApps(String gid) => _apps(gid).snapshots().map((s) =>
      s.docs.map((d) => StoreApp.fromDoc(gid, d)).toList()
        ..sort((a, b) {
          final o = a.order.compareTo(b.order);
          return o != 0 ? o : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }));

  Future<void> saveApp(String gid, StoreApp app) {
    final data = {...app.toEditableJson(), 'updatedAt': FieldValue.serverTimestamp()};
    if (app.id.isEmpty) return _apps(gid).add({...data, 'createdAt': FieldValue.serverTimestamp()});
    return _apps(gid).doc(app.id).set(data, SetOptions(merge: true));
  }

  Future<void> deleteApp(String gid, String appId) => _apps(gid).doc(appId).delete();

  // ------------------------------------------------------------------ biblioteka (administrator)

  CollectionReference<Map<String, dynamic>> get _library => db.collection('library');

  /// Wszystkie aplikacje administratora (library/{pakiet}), także nieprzypisane do żadnej grupy.
  Stream<List<StoreApp>> watchLibrary() => _library.snapshots().map((s) =>
      s.docs.map((d) => StoreApp.fromDoc('', d)).toList()
        ..sort((a, b) {
          final o = a.order.compareTo(b.order);
          return o != 0 ? o : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }));

  /// Pole `latest` w formacie Firestore (publishedAt jako Timestamp).
  static Map<String, dynamic> latestToFirestore(AppRelease r) {
    final j = r.toJson();
    if (r.publishedAt != null) j['publishedAt'] = Timestamp.fromDate(r.publishedAt!);
    return j;
  }

  Map<String, dynamic> _appData(StoreApp app, {AppRelease? latest}) => {
        ...app.toEditableJson(),
        if ((latest ?? app.latest) != null) 'latest': latestToFirestore((latest ?? app.latest)!),
        'updatedAt': FieldValue.serverTimestamp(),
      };

  /// Zapis do biblioteki (id = pakiet) i odświeżenie kopii we wszystkich grupach.
  Future<void> saveLibraryApp(StoreApp app, List<StoreGroup> ownedGroups, {AppRelease? latest}) async {
    final pkg = app.packageName.trim();
    await _library.doc(pkg).set(_appData(app, latest: latest), SetOptions(merge: true));
    for (final g in ownedGroups) {
      final copies = await _apps(g.id).where('packageName', isEqualTo: pkg).get();
      for (final c in copies.docs) {
        await c.reference.set(_appData(app, latest: latest), SetOptions(merge: true));
      }
    }
  }

  /// Usunięcie z biblioteki i ze wszystkich grup.
  Future<void> deleteLibraryApp(String packageName, List<StoreGroup> ownedGroups) async {
    for (final g in ownedGroups) {
      await unassignApp(g.id, packageName);
    }
    await _library.doc(packageName).delete();
  }

  /// Udostępnienie aplikacji z biblioteki grupie (kopia wpisu w groups/{gid}/apps/{pakiet}).
  Future<void> assignApp(String gid, StoreApp app) async {
    final existing = await _apps(gid).where('packageName', isEqualTo: app.packageName).limit(1).get();
    if (existing.docs.isNotEmpty) return;
    await _apps(gid).doc(app.packageName).set({..._appData(app), 'createdAt': FieldValue.serverTimestamp()});
  }

  Future<void> unassignApp(String gid, String packageName) async {
    final copies = await _apps(gid).where('packageName', isEqualTo: packageName).get();
    for (final c in copies.docs) {
      await c.reference.delete();
    }
  }

  /// Ustawia dokładnie te grupy, w których ma być aplikacja.
  Future<void> setAppGroups(StoreApp app, Set<String> groupIds, List<StoreGroup> ownedGroups) async {
    for (final g in ownedGroups) {
      if (groupIds.contains(g.id)) {
        await assignApp(g.id, app);
      } else {
        await unassignApp(g.id, app.packageName);
      }
    }
  }

  // ------------------------------------------------------------------ konta (administrator)

  /// Wszystkie konta z książki adresowej (Zakupy, Powrót, Sklep) - tylko administrator może je wylistować.
  Stream<List<UserAccount>> watchUsers() => db.collection('emails').snapshots().map((s) => s.docs
      .map((d) => UserAccount(uid: (d.data()['uid'] as String?) ?? '', email: (d.data()['email'] as String?) ?? d.id))
      .where((u) => u.uid.isNotEmpty)
      .toList()
    ..sort((a, b) => a.email.compareTo(b.email)));

  /// Ustawia dokładnie te grupy (spośród prowadzonych), do których należy osoba.
  Future<void> setUserGroups(UserAccount user, Set<String> groupIds, List<StoreGroup> ownedGroups) async {
    for (final g in ownedGroups) {
      if (user.uid == g.ownerId) continue; // administratora nie wypisujemy z jego grup
      final inside = g.members.contains(user.uid);
      if (groupIds.contains(g.id) && !inside) {
        await _groups.doc(g.id).update({
          'members': FieldValue.arrayUnion([user.uid]),
          FieldPath(['memberEmails', user.uid]): emailKey(user.email),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } else if (!groupIds.contains(g.id) && inside) {
        await removeMember(g.id, user.uid);
      }
    }
  }

  // ------------------------------------------------------------------ zaproszenia

  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // bez 0/O, 1/I

  Future<Invite> createInvite(StoreGroup group) async {
    final rnd = Random.secure();
    final code = List.generate(8, (_) => _alphabet[rnd.nextInt(_alphabet.length)]).join();
    final expires = DateTime.now().add(StoreConfig.inviteValidity);
    await db.collection('invites').doc(code).set({
      'groupId': group.id,
      'groupName': group.name,
      'createdBy': uid,
      'expiresAt': Timestamp.fromDate(expires),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return Invite(code: code, groupId: group.id, groupName: group.name, createdBy: uid, expiresAt: expires);
  }

  Stream<List<Invite>> watchMyInvites(String gid) => db
      .collection('invites')
      .where('createdBy', isEqualTo: uid)
      .snapshots()
      .map((s) => s.docs.map(Invite.fromDoc).where((i) => i.groupId == gid).toList()
        ..sort((a, b) => b.expiresAt.compareTo(a.expiresAt)));

  Future<void> deleteInvite(String code) => db.collection('invites').doc(code).delete();

  /// Kod z linku albo wpisany ręcznie: wielkie litery, bez spacji i myślników.
  static String normalizeCode(String raw) => raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Dołączenie do grupy kodem. Zwraca nazwę grupy.
  Future<String> joinWithCode(String rawCode) async {
    final code = normalizeCode(rawCode);
    if (code.length < 6) throw const JoinException('Za krótki kod zaproszenia.');
    final snap = await db.collection('invites').doc(code).get();
    if (!snap.exists) throw const JoinException('Nie ma takiego zaproszenia. Sprawdź kod.');
    final invite = Invite.fromDoc(snap);
    if (!invite.isValid) throw const JoinException('Zaproszenie wygasło. Poproś o nowe.');
    try {
      await _groups.doc(invite.groupId).update({
        'members': FieldValue.arrayUnion([uid]),
        FieldPath(['memberEmails', uid]): emailKey(email),
        'lastInvite': code,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (e) {
      if (e.code != 'permission-denied') rethrow;
      // Reguły odrzucają też ponowne dołączenie - sprawdź, czy już jesteśmy w grupie.
      try {
        final g = await _groups.doc(invite.groupId).get();
        if (g.exists && StoreGroup.fromDoc(g).members.contains(uid)) return invite.groupName;
      } catch (_) {}
      throw const JoinException('Nie udało się dołączyć - zaproszenie jest nieważne.');
    }
    return invite.groupName;
  }

  // ------------------------------------------------------------------ kto ma którą wersję

  Future<void> reportInstall(String gid, InstalledApp app) =>
      _groups.doc(gid).collection('installs').doc('${uid}_${app.packageName}').set({
        'uid': uid,
        'email': emailKey(email),
        'packageName': app.packageName,
        'versionName': app.versionName,
        'versionCode': app.versionCode,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> clearInstall(String gid, String packageName) =>
      _groups.doc(gid).collection('installs').doc('${uid}_$packageName').delete();

  Stream<List<InstallReport>> watchInstalls(String gid) => _groups
      .doc(gid)
      .collection('installs')
      .snapshots()
      .map((s) => s.docs.map(InstallReport.fromDoc).toList());
}
