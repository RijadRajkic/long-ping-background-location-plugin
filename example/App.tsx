/**
 * Long Ping example: tracking state, last fix, queue and an activity log, with buttons for every command.
 * The same commands arrive over deep links (src/commands.ts), so this screen doubles as the e2e rig.
 *
 * @format
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  AppState,
  Pressable,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  useColorScheme,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import LongPing, { type Location, type State } from 'react-native-long-ping';
import { runCommand } from './src/commands';
import { HOST } from './src/config';
import { onEntry, type Entry } from './src/report';

const LOG_TAIL = 60;

const light = {
  bg: '#F4F5F7',
  card: '#FFFFFF',
  text: '#111418',
  muted: '#5E6670',
  line: '#E3E6EA',
  accent: '#1F6FEB',
  good: '#1A7F37',
  bad: '#CF222E',
  warn: '#9A6700',
  buttonText: '#FFFFFF',
};
const dark: typeof light = {
  bg: '#0D1117',
  card: '#161B22',
  text: '#E6EDF3',
  muted: '#8D96A0',
  line: '#30363D',
  accent: '#4493F8',
  good: '#3FB950',
  bad: '#F85149',
  warn: '#D29922',
  buttonText: '#FFFFFF',
};
type Palette = typeof light;

const ACTIONS: { label: string; name: string; args?: Record<string, string> }[] = [
  { label: 'Start', name: 'start' },
  { label: 'Stop', name: 'stop' },
  { label: 'Moving', name: 'changePace', args: { moving: '1' } },
  { label: 'Parked', name: 'changePace', args: { moving: '0' } },
  { label: 'Locate + save', name: 'getCurrentPosition', args: { persist: '1' } },
  { label: 'Sync', name: 'sync' },
  { label: 'Permission', name: 'requestPermission', args: { level: 'always' } },
  { label: 'Upload log', name: 'uploadLog' },
  { label: 'Settings', name: 'openSettings' },
];

function App() {
  const scheme = useColorScheme();
  const palette = scheme === 'dark' ? dark : light;
  return (
    <SafeAreaProvider>
      <StatusBar barStyle={scheme === 'dark' ? 'light-content' : 'dark-content'} />
      <Screen palette={palette} />
    </SafeAreaProvider>
  );
}

function Screen({ palette: p }: { palette: Palette }) {
  const [state, setState] = useState<State | null>(null);
  const [entries, setEntries] = useState<Entry[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [, setTick] = useState(0);
  const lastRefresh = useRef(0);

  const refresh = useCallback(() => {
    lastRefresh.current = Date.now();
    LongPing.getState().then(setState, () => undefined);
  }, []);

  useEffect(() => {
    refresh();
    const off = onEntry((entry) => {
      setEntries((prev) => [entry, ...prev].slice(0, LOG_TAIL));
      if (Date.now() - lastRefresh.current > 1000) refresh();
    });
    const timer = setInterval(() => {
      if (AppState.currentState === 'active') {
        refresh();
        setTick((t) => t + 1);
      }
    }, 5000);
    return () => {
      off();
      clearInterval(timer);
    };
  }, [refresh]);

  const run = async (label: string, name: string, args?: Record<string, string>) => {
    setBusy(label);
    await runCommand(name, args);
    setBusy(null);
    refresh();
  };

  const s = styles(p);
  const fix = state?.lastLocation ?? null;

  return (
    <SafeAreaView style={s.root} edges={['top', 'left', 'right']}>
      <ScrollView contentContainerStyle={s.content}>
        <View style={s.header}>
          <Text style={s.title}>Long Ping</Text>
          <Text style={s.subtitle}>Uploads to {HOST}</Text>
        </View>

        <View style={s.card}>
          <Row p={p} label="Tracking" value={state ? (state.enabled ? 'On' : 'Off') : '…'} tone={state?.enabled ? 'good' : 'muted'} />
          <Row
            p={p}
            label="Motion"
            value={state ? (state.enabled ? (state.isMoving ? 'Moving' : 'Parked') : '—') : '…'}
          />
          <Row
            p={p}
            label="Uploads"
            value={state ? (state.authorizationRequired ? 'Paused: token rejected' : 'Authorized') : '…'}
            tone={state?.authorizationRequired ? 'bad' : 'muted'}
          />
          <Row p={p} label="Queue" value={state ? `${state.queueCount} record(s)` : '…'} last />
        </View>

        <Text style={s.section}>Last fix</Text>
        <View style={s.card}>{fix ? <FixView p={p} fix={fix} /> : <Text style={s.muted}>No fix recorded yet.</Text>}</View>

        <Text style={s.section}>Actions</Text>
        <View style={s.grid}>
          {ACTIONS.map((a) => (
            <Pressable
              key={a.label}
              accessibilityRole="button"
              disabled={busy !== null}
              onPress={() => run(a.label, a.name, a.args)}
              style={({ pressed }) => [s.button, (pressed || busy === a.label) && s.buttonPressed]}>
              <Text style={s.buttonText}>{busy === a.label ? '…' : a.label}</Text>
            </Pressable>
          ))}
        </View>

        <Text style={s.section}>Activity</Text>
        <View style={s.card}>
          {entries.length === 0 ? (
            <Text style={s.muted}>Events and command results appear here.</Text>
          ) : (
            entries.map((e, i) => <EntryRow key={`${e.at}-${i}`} p={p} entry={e} last={i === entries.length - 1} />)
          )}
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

function Row({ p, label, value, tone = 'text', last }: { p: Palette; label: string; value: string; tone?: 'text' | 'muted' | 'good' | 'bad' | 'warn'; last?: boolean }) {
  const s = styles(p);
  return (
    <View style={[s.row, !last && s.rowLine]}>
      <Text style={s.rowLabel}>{label}</Text>
      <Text style={[s.rowValue, { color: p[tone] }]}>{value}</Text>
    </View>
  );
}

function FixView({ p, fix }: { p: Palette; fix: Location }) {
  const s = styles(p);
  const ageSec = Math.max(0, Math.round((Date.now() - Date.parse(fix.timestamp)) / 1000));
  const c = fix.coords;
  return (
    <View>
      <Text style={s.coords}>
        {c.latitude.toFixed(5)}, {c.longitude.toFixed(5)}
      </Text>
      <Text style={s.muted}>
        ±{Math.round(c.accuracy)} m · {c.speed >= 0 ? `${Math.round(c.speed * 3.6)} km/h` : 'speed unknown'} · {fix.event}
        {fix.mock ? ' · simulated' : ''}
      </Text>
      <Text style={s.muted}>
        {new Date(fix.timestamp).toLocaleTimeString()} ({ageSec} s ago)
      </Text>
    </View>
  );
}

function summary(e: Entry): string {
  const x = e.payload as any;
  if (e.kind === 'event') {
    switch (e.name) {
      case 'location':
        return `${x?.event} ±${Math.round(x?.coords?.accuracy ?? -1)} m`;
      case 'motionchange':
        return x?.isMoving ? 'moving' : 'parked';
      case 'http':
        return `HTTP ${x?.status} · ${x?.count} record(s)`;
      case 'enabledchange':
        return x?.enabled ? 'enabled' : 'disabled';
      case 'authorization':
        return `${x?.status} ${x?.error ?? ''}`;
      case 'error':
        return `${x?.code}: ${x?.message}`;
      default:
        return '';
    }
  }
  if (!e.ok && x?.code) return `${x.code}: ${x.message}`;
  if (typeof x === 'number' || typeof x === 'boolean') return String(x);
  if (e.name === 'uploadLog') return `${x?.lines} line(s) sent`;
  if (x && typeof x === 'object' && 'enabled' in x) return `enabled ${x.enabled}, queue ${x.queueCount}`;
  if (x?.appState) return x.appState;
  return e.ok ? 'ok' : 'failed';
}

function EntryRow({ p, entry, last }: { p: Palette; entry: Entry; last: boolean }) {
  const s = styles(p);
  const time = entry.at.slice(11, 19);
  return (
    <View style={[s.entry, !last && s.rowLine]}>
      <Text style={s.entryTime}>{time}</Text>
      <View style={[s.dot, { backgroundColor: entry.ok ? p.good : p.bad }]} />
      <Text style={s.entryName} numberOfLines={1}>
        {entry.kind === 'cmd' ? `${entry.name}()` : entry.name}
      </Text>
      <Text style={s.entryText} numberOfLines={1}>
        {summary(entry)}
      </Text>
    </View>
  );
}

const cache = new Map<Palette, ReturnType<typeof makeStyles>>();
const styles = (p: Palette) => {
  let s = cache.get(p);
  if (!s) {
    s = makeStyles(p);
    cache.set(p, s);
  }
  return s;
};

const makeStyles = (p: Palette) =>
  StyleSheet.create({
    root: { flex: 1, backgroundColor: p.bg },
    content: { padding: 16, paddingBottom: 48 },
    header: { marginBottom: 16 },
    title: { fontSize: 28, fontWeight: '700', color: p.text },
    subtitle: { fontSize: 13, color: p.muted, marginTop: 2 },
    section: { fontSize: 15, fontWeight: '600', color: p.text, marginTop: 20, marginBottom: 8 },
    card: {
      backgroundColor: p.card,
      borderRadius: 12,
      paddingHorizontal: 14,
      paddingVertical: 6,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: p.line,
    },
    row: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 10 },
    rowLine: { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: p.line },
    rowLabel: { fontSize: 15, color: p.muted },
    rowValue: { fontSize: 15, fontWeight: '600' },
    coords: { fontSize: 20, fontWeight: '600', color: p.text, marginTop: 6, fontVariant: ['tabular-nums'] },
    muted: { fontSize: 13, color: p.muted, marginVertical: 4 },
    grid: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
    button: {
      flexGrow: 1,
      flexBasis: '30%',
      backgroundColor: p.accent,
      borderRadius: 10,
      paddingVertical: 12,
      alignItems: 'center',
    },
    buttonPressed: { opacity: 0.6 },
    buttonText: { color: p.buttonText, fontSize: 14, fontWeight: '600' },
    entry: { flexDirection: 'row', alignItems: 'center', paddingVertical: 7, gap: 8 },
    entryTime: { fontSize: 12, color: p.muted, fontVariant: ['tabular-nums'] },
    dot: { width: 7, height: 7, borderRadius: 4 },
    entryName: { fontSize: 13, fontWeight: '600', color: p.text, width: 132 },
    entryText: { fontSize: 13, color: p.muted, flex: 1 },
  });

export default App;
