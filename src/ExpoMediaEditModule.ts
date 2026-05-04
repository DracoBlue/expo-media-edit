import { EventEmitter, requireNativeModule } from 'expo-modules-core';

const ExpoMediaEditNativeModule = requireNativeModule('ExpoMediaEdit');
export const emitter = new EventEmitter(ExpoMediaEditNativeModule);

export default ExpoMediaEditNativeModule;
