// Codegen spec. The method list and signatures here are the bridge contract both native modules
// implement (see DESIGN.md, "Bridge methods"). Objects cross as untyped maps; src/index.ts puts the
// real types on top.
import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export interface Spec extends TurboModule {
  configure(config: Object): Promise<Object>;
  setConfig(config: Object): Promise<Object>;
  start(): Promise<Object>;
  stop(): Promise<Object>;
  getState(): Promise<Object>;
  setAuthorization(auth: Object): Promise<void>;
  clearAuthorization(): Promise<void>;
  getCurrentPosition(options: Object): Promise<Object>;
  changePace(isMoving: boolean): Promise<Object>;
  sync(): Promise<number>;
  getQueueCount(): Promise<number>;
  clearQueue(): Promise<void>;
  getProviderState(): Promise<Object>;
  requestPermission(level: string): Promise<number>;
  isIgnoringBatteryOptimizations(): Promise<boolean>;
  requestIgnoreBatteryOptimizations(): Promise<boolean>;
  openPowerManagerSettings(): Promise<boolean>;
  openAppSettings(): Promise<boolean>;
  openLocationSettings(): Promise<boolean>;
  getLog(options: Object): Promise<string>;
  clearLog(): Promise<void>;

  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('LongPing');
