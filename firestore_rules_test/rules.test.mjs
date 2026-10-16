// Tests ../firestore.rules against the Firestore emulator.
// Each "app:" test replays a Firestore operation the Flutter app performs,
// so a rules change that would break the app fails here first. The other
// tests try what an attacker could.
//
//   npm install && npm test

import { readFileSync } from 'node:fs';
import { after, before, beforeEach, describe, test } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  Timestamp,
  addDoc,
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  limit,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
  writeBatch,
} from 'firebase/firestore';

const HOUR = 60 * 60 * 1000;
const inHours = (h) => Timestamp.fromMillis(Date.now() + h * HOUR);
const SID = 'session123456';
const exp = () => ({ expiresAt: inHours(24 * 7) });

let env;
/** Signed-in devices (anonymous auth): the admin, a camera, someone else. */
let admin;
let camera;
let intruder;
/** A client that never signed in. */
let anon;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-multicam',
    firestore: { rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8') },
  });
});

after(async () => env?.cleanup());

beforeEach(async () => {
  await env.clearFirestore();
  admin = env.authenticatedContext('admin-uid').firestore();
  camera = env.authenticatedContext('camera-uid').firestore();
  intruder = env.authenticatedContext('intruder-uid').firestore();
  anon = env.unauthenticatedContext().firestore();
});

/** Seeds data bypassing the rules. */
const seed = (fn) => env.withSecurityRulesDisabled((ctx) => fn(ctx.firestore()));

/** Mirrors FirebaseSessionDataSource.createSession's transaction. */
function createSession(db, code, { sessionId = SID, adminUid = 'admin-uid' } = {}) {
  const codeRef = doc(db, 'session_codes', code);
  const sessionRef = doc(db, 'sessions', sessionId);
  return runTransaction(db, async (tx) => {
    await tx.get(codeRef);
    tx.set(sessionRef, {
      adminId: 'admin-1',
      adminUid,
      status: 'waiting',
      code,
      createdAt: serverTimestamp(),
      ...exp(),
    });
    tx.set(codeRef, { sessionId, createdAt: serverTimestamp(), expiresAt: inHours(24) });
  });
}

/** Mirrors FirebaseSessionDataSource.endSession's transaction. */
function endSession(db, sessionId = SID) {
  const sessionRef = doc(db, 'sessions', sessionId);
  return runTransaction(db, async (tx) => {
    const session = await tx.get(sessionRef);
    const codeRef = doc(db, 'session_codes', session.data().code);
    const codeDoc = await tx.get(codeRef);
    if (codeDoc.data()?.sessionId === sessionId) tx.delete(codeRef);
    tx.update(sessionRef, { status: 'ended' });
  });
}

/** Mirrors FirebaseSignalingDataSource.registerDevice. */
const registerCamera = (db, peerId = 'peer-1', uid = 'camera-uid') =>
  setDoc(
    doc(db, 'sessions', SID, 'peers', peerId),
    { deviceName: 'Pixel', uid, joinedAt: serverTimestamp(), capabilities: [], ...exp() },
    { merge: true },
  );

const sessionDoc = (db) => doc(db, 'sessions', SID);
const peerDoc = (db, peerId = 'peer-1') => doc(db, 'sessions', SID, 'peers', peerId);
const sub = (db, ...path) => collection(db, 'sessions', SID, ...path);
const command = (extra = {}) => ({
  type: 'startRecording',
  issuedAt: serverTimestamp(),
  bufferMs: 1000,
  targetPeerId: null,
  payload: null,
  ...exp(),
  ...extra,
});

describe('authentication', () => {
  test('a device that never signed in can do nothing', async () => {
    await createSession(admin, '123456');
    await assertFails(createSession(anon, '654321', { sessionId: 'x', adminUid: 'none' }));
    await assertFails(getDoc(doc(anon, 'session_codes', '123456')));
    await assertFails(getDoc(sessionDoc(anon)));
    await assertFails(getDocs(sub(anon, 'peers')));
    await assertFails(setDoc(doc(collection(anon, '_clock_probes')), { t: serverTimestamp() }));
  });
});

describe('session lifecycle', () => {
  test('app: admin creates a session under a free code', async () => {
    await assertSucceeds(createSession(admin, '123456'));
  });

  test('a session cannot be created in someone else\'s name', async () => {
    await assertFails(createSession(intruder, '123456', { adminUid: 'admin-uid' }));
  });

  test('app: camera resolves a code and reads the session', async () => {
    await createSession(admin, '123456');
    await assertSucceeds(getDoc(doc(camera, 'session_codes', '123456')));
    await assertSucceeds(getDoc(sessionDoc(camera)));
  });

  test("a live session's code cannot be overwritten", async () => {
    await createSession(admin, '123456');
    await assertFails(createSession(intruder, '123456', { sessionId: 'evil', adminUid: 'intruder-uid' }));
  });

  test('app: an expired code can be claimed by a new session', async () => {
    await seed((sdb) =>
      setDoc(doc(sdb, 'session_codes', '123456'), {
        sessionId: 'old',
        createdAt: Timestamp.fromMillis(Date.now() - 48 * HOUR),
        expiresAt: Timestamp.fromMillis(Date.now() - HOUR),
      }),
    );
    await assertSucceeds(createSession(admin, '123456', { sessionId: 'newSession' }));
  });

  test('a legacy code without expiresAt expires 24 h after createdAt', async () => {
    await seed(async (sdb) => {
      await setDoc(doc(sdb, 'session_codes', '111111'), {
        sessionId: 'old',
        createdAt: Timestamp.fromMillis(Date.now() - 25 * HOUR),
      });
      await setDoc(doc(sdb, 'session_codes', '222222'), {
        sessionId: 'recent',
        createdAt: Timestamp.fromMillis(Date.now() - HOUR),
      });
    });
    await assertSucceeds(createSession(admin, '111111', { sessionId: 'a' }));
    await assertFails(createSession(admin, '222222', { sessionId: 'b' }));
  });

  test('codes and sessions cannot be listed', async () => {
    await createSession(admin, '123456');
    await assertFails(getDocs(collection(intruder, 'session_codes')));
    await assertFails(getDocs(collection(intruder, 'sessions')));
  });

  test('malformed codes and sessions are rejected', async () => {
    await assertFails(
      setDoc(doc(admin, 'session_codes', 'abc'), { sessionId: SID, createdAt: serverTimestamp() }),
    );
    await assertFails(
      setDoc(sessionDoc(admin), {
        adminId: 'a',
        adminUid: 'admin-uid',
        status: 'live',
        code: '123456',
        createdAt: serverTimestamp(),
      }),
    );
  });

  test('app: admin ends a session, freeing its code', async () => {
    await createSession(admin, '123456');
    await assertSucceeds(endSession(admin));
    const code = await getDoc(doc(admin, 'session_codes', '123456'));
    if (code.exists()) throw new Error('code should be freed');
  });

  test('only the admin can end a session or free its code', async () => {
    await createSession(admin, '123456');
    await assertFails(endSession(camera));
    await assertFails(updateDoc(sessionDoc(intruder), { status: 'ended' }));
    await assertFails(deleteDoc(doc(intruder, 'session_codes', '123456')));
  });

  test('only the status can change, and ended is final', async () => {
    await createSession(admin, '123456');
    await assertFails(updateDoc(sessionDoc(admin), { adminUid: 'intruder-uid' }));
    await assertFails(updateDoc(sessionDoc(admin), { status: 'hacked' }));
    await endSession(admin);
    await assertFails(updateDoc(sessionDoc(admin), { status: 'waiting' }));
  });

  test('a live session cannot be deleted; its admin can delete it once ended', async () => {
    await createSession(admin, '123456');
    await assertFails(deleteDoc(sessionDoc(admin)));
    await endSession(admin);
    await assertFails(deleteDoc(sessionDoc(intruder)));
    await assertSucceeds(deleteDoc(sessionDoc(admin)));
  });
});

describe('signaling', () => {
  beforeEach(() => createSession(admin, '123456'));

  test('app: camera registers, admin offers, camera answers, both exchange ICE', async () => {
    await assertSucceeds(registerCamera(camera));
    await assertSucceeds(getDocs(sub(admin, 'peers'))); // watchPeers
    await assertSucceeds(
      setDoc(peerDoc(admin), { offer: { sdp: 'v=0', type: 'offer' }, ...exp() }, { merge: true }),
    );
    await assertSucceeds(getDoc(peerDoc(camera))); // watchOffer
    await assertSucceeds(
      setDoc(peerDoc(camera), { answer: { sdp: 'v=0', type: 'answer' }, ...exp() }, { merge: true }),
    );
    const ice = { candidate: 'candidate:1 1 udp 1 192.168.1.2 5000 typ host', sdpMid: '0', sdpMLineIndex: 0, ...exp() };
    await assertSucceeds(addDoc(sub(admin, 'peers', 'peer-1', 'admin_candidates'), ice));
    await assertSucceeds(addDoc(sub(camera, 'peers', 'peer-1', 'camera_candidates'), ice));
    await assertSucceeds(getDocs(sub(camera, 'peers', 'peer-1', 'admin_candidates')));
    await assertSucceeds(getDocs(sub(admin, 'peers', 'peer-1', 'camera_candidates')));
  });

  test('app: either side clears signaling', async () => {
    await registerCamera(camera);
    await setDoc(peerDoc(admin), { offer: { sdp: 'v=0', type: 'offer' } }, { merge: true });
    await addDoc(sub(admin, 'peers', 'peer-1', 'admin_candidates'), { candidate: 'c' });
    for (const db of [camera, admin]) {
      await assertSucceeds(updateDoc(peerDoc(db), { offer: deleteField(), answer: deleteField() }));
      const cands = await getDocs(query(sub(db, 'peers', 'peer-1', 'admin_candidates'), limit(500)));
      const batch = writeBatch(db);
      cands.docs.forEach((d) => batch.delete(d.ref));
      await assertSucceeds(batch.commit());
    }
  });

  test("nobody else can take over or impersonate a camera", async () => {
    await registerCamera(camera);
    // Steal the peer document, or register under someone else's UID.
    await assertFails(setDoc(peerDoc(intruder), { deviceName: 'x', uid: 'intruder-uid' }, { merge: true }));
    await assertFails(registerCamera(intruder, 'peer-2', 'camera-uid'));
    // Inject ICE candidates or answers in the camera's name.
    await assertFails(addDoc(sub(intruder, 'peers', 'peer-1', 'camera_candidates'), { candidate: 'c' }));
    await assertFails(setDoc(peerDoc(intruder), { answer: { sdp: 'x', type: 'answer' } }, { merge: true }));
    // Or in the admin's name.
    await assertFails(addDoc(sub(camera, 'peers', 'peer-1', 'admin_candidates'), { candidate: 'c' }));
    await assertFails(setDoc(peerDoc(camera), { offer: { sdp: 'x', type: 'offer' }, uid: 'admin-uid' }, { merge: true }));
  });

  test('the admin cannot rewrite camera-owned fields', async () => {
    await registerCamera(camera);
    await assertFails(updateDoc(peerDoc(admin), { deviceName: 'renamed' }));
    await assertFails(updateDoc(peerDoc(admin), { uid: 'admin-uid' }));
  });
});

describe('commands, recordings and timeline', () => {
  beforeEach(async () => {
    await createSession(admin, '123456');
    await registerCamera(camera);
  });

  test('app: admin publishes timed commands, cameras watch them', async () => {
    await assertSucceeds(setDoc(doc(sub(admin, 'commands')), command({ executeAtMs: Date.now() + 1000 })));
    await assertSucceeds(
      getDocs(query(sub(camera, 'commands'), where('issuedAt', '>=', Timestamp.fromMillis(Date.now() - 10_000)))),
    );
  });

  test('app: a co-admin camera switches the program feed', async () => {
    await assertSucceeds(
      setDoc(
        doc(sub(camera, 'commands')),
        command({ type: 'switchActiveCamera', bufferMs: 0, payload: { peerId: 'peer-2', senderPeerId: 'peer-1' } }),
      ),
    );
  });

  test('cameras and strangers cannot issue other commands', async () => {
    await assertFails(setDoc(doc(sub(camera, 'commands')), command({ type: 'stopRecording' })));
    await assertFails(setDoc(doc(sub(intruder, 'commands')), command()));
    // A switch in another camera's name.
    await assertFails(
      setDoc(
        doc(sub(intruder, 'commands')),
        command({ type: 'switchActiveCamera', payload: { peerId: 'peer-1', senderPeerId: 'peer-1' } }),
      ),
    );
  });

  test('app: camera publishes its recording, admin reads and deletes it', async () => {
    const rec = await assertSucceeds(
      addDoc(sub(camera, 'recordings'), {
        peerId: 'peer-1',
        filename: 'rec.mp4',
        localIp: '192.168.1.2',
        port: 8080,
        sizeBytes: 1,
        recordedAt: serverTimestamp(),
        ...exp(),
      }),
    );
    await assertSucceeds(getDocs(sub(admin, 'recordings')));
    await assertFails(deleteDoc(doc(camera, rec.path)));
    await assertSucceeds(deleteDoc(doc(admin, rec.path)));
  });

  test('a recording cannot be published for another camera', async () => {
    await assertFails(addDoc(sub(intruder, 'recordings'), { peerId: 'peer-1', filename: 'evil.mp4' }));
  });

  test('app: admin writes, reads and clears the timeline', async () => {
    await assertSucceeds(addDoc(sub(admin, 'timeline'), { timestamp: new Date().toISOString(), peerId: 'peer-1', ...exp() }));
    await assertSucceeds(getDocs(query(sub(admin, 'timeline'), orderBy('timestamp'))));
    const tl = await getDocs(sub(admin, 'timeline'));
    const batch = writeBatch(admin);
    tl.docs.forEach((d) => batch.delete(d.ref));
    await assertSucceeds(batch.commit());
  });

  test('only the admin writes the timeline', async () => {
    await assertFails(addDoc(sub(camera, 'timeline'), { timestamp: 'x', peerId: 'peer-1' }));
  });

  test('app: after ending, no new data, but the admin can clean everything up', async () => {
    const rec = await addDoc(sub(camera, 'recordings'), { peerId: 'peer-1', ...exp() });
    await endSession(admin);
    await assertFails(setDoc(doc(sub(admin, 'commands')), command()));
    await assertFails(addDoc(sub(camera, 'recordings'), { peerId: 'peer-1' }));
    await assertSucceeds(deleteDoc(doc(admin, rec.path)));
    await assertSucceeds(deleteDoc(peerDoc(admin)));
    await assertSucceeds(deleteDoc(sessionDoc(admin)));
  });

  test('nothing can be written into a session that does not exist', async () => {
    await assertFails(addDoc(collection(admin, 'sessions', 'missing', 'commands'), command()));
  });
});

describe('other collections', () => {
  test('app: clock probes are written, read back and deleted', async () => {
    const probe = doc(collection(camera, '_clock_probes'));
    await assertSucceeds(setDoc(probe, { t: serverTimestamp(), ...exp() }));
    await assertSucceeds(getDoc(probe));
    await assertSucceeds(deleteDoc(probe));
  });

  test('clock probes cannot be listed or hold other data', async () => {
    await assertFails(getDocs(collection(camera, '_clock_probes')));
    await assertFails(setDoc(doc(collection(camera, '_clock_probes')), { t: serverTimestamp(), x: 1 }));
  });

  test('collections the app does not use are denied', async () => {
    await assertFails(setDoc(doc(admin, 'anything', 'x'), { a: 1 }));
    await assertFails(getDoc(doc(admin, 'users', 'x')));
  });
});
