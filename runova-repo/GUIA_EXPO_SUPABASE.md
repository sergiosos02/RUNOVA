# De la demo web a RUNOVA real: React Native + Expo + Supabase

Esta guía parte de dos cosas que ya tienes: la demo web (`runova.html`) y el esquema de base de datos (`runova_schema.sql`). El objetivo es llegar a una app instalable en iOS/Android con datos reales y persistentes.

## 0. Antes de empezar

Necesitas Node.js instalado y una cuenta en [supabase.com](https://supabase.com). Todo el trabajo de código se hace mejor en **Claude Code** (terminal, VS Code o la app de escritorio), no en este chat: aquí puedo darte el plan y fragmentos de código, pero el desarrollo iterativo de una app completa se hace en tu propio entorno.

Si ya ejecutaste `runova_schema.sql` en el SQL Editor de tu proyecto de Supabase, tienes el backend listo. Si no, hazlo primero.

## 1. Crear el proyecto Expo

```bash
npx create-expo-app runova -t
cd runova
npx expo install expo-router expo-location expo-image-picker expo-notifications
npm install @supabase/supabase-js @react-native-async-storage/async-storage react-native-url-polyfill
```

Usa `expo-router` (navegación basada en archivos) en vez de montar tú mismo React Navigation: es más rápido de estructurar y se parece a cómo ya está organizada la demo (una pantalla = una vista).

Estructura de carpetas recomendada:

```
app/
  (auth)/login.tsx
  (auth)/onboarding.tsx
  (tabs)/home.tsx
  (tabs)/activity.tsx
  (tabs)/explore.tsx
  (tabs)/profile.tsx
  activity/track.tsx        <- pantalla de GPS en vivo
  activity/new.tsx
  nutrition/index.tsx
  nutrition/scan.tsx         <- escáner de alimentos
  event/[id].tsx
  event/[id]/chat.tsx
lib/
  supabase.ts
  api/ (activities.ts, meals.ts, posts.ts, events.ts...)
components/
```

## 2. Conectar Supabase

`lib/supabase.ts`:

```ts
import 'react-native-url-polyfill/auto';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';

export const supabase = createClient(
  process.env.EXPO_PUBLIC_SUPABASE_URL!,
  process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY!,
  {
    auth: { storage: AsyncStorage, autoRefreshToken: true, persistSession: true, detectSessionInUrl: false },
  }
);
```

Guarda la URL y la clave `anon` del proyecto (Settings → API en Supabase) en un archivo `.env` con prefijo `EXPO_PUBLIC_`. Nunca pongas la clave `service_role` en la app: esa solo se usa en el panel de administración, desde un backend.

## 3. Autenticación

Sustituye el `finish()` de la demo (que solo guardaba en `localStorage`) por:

```ts
// registro
const { data, error } = await supabase.auth.signUp({ email, password });
// tras confirmar email, crear la fila en profiles con el mismo id:
await supabase.from('profiles').insert({ id: data.user.id, username, name, goal, account_type });
```

Para Google/Apple usa `supabase.auth.signInWithOAuth` con `expo-auth-session`, siguiendo la guía oficial de Supabase para Expo (el flujo exacto cambia de vez en cuando, consúltala en el momento de implementarlo). Mantén el onboarding de 5 pantallas de la demo tal cual: solo cambia el guardado final de `localStorage` a estas llamadas.

## 4. Capa de datos (sustituye a `S` y `save()`)

En la demo, todo el estado vivía en un objeto `S` guardado en `localStorage`. Ahora cada pantalla lee y escribe directamente en Supabase. Ejemplo para actividades (`lib/api/activities.ts`):

```ts
export async function createActivity(a: {sport_id:number; distance_km:number; duration_s:number; calories_kcal:number; note?:string; visibility:string}) {
  const { data: { user } } = await supabase.auth.getUser();
  const { data, error } = await supabase.from('activities').insert({ ...a, user_id: user!.id }).select().single();
  if (error) throw error;
  return data;
}

export function useFeed() {
  return supabase
    .from('posts')
    .select('*, profiles(username, name, avatar_url), activities(*), meals(*)')
    .order('created_at', { ascending: false })
    .limit(20);
}
```

Como la base de datos ya aplica Row Level Security, no necesitas replicar en el cliente la lógica de "¿puede ver esto?" que tenía la demo (`S.follows`, `S.blocked`, etc.): si la consulta no debería devolver una fila, Supabase ya la filtra.

## 5. GPS en vivo

La demo dibujaba la ruta con `navigator.geolocation.watchPosition` y un SVG. En Expo:

```ts
import * as Location from 'expo-location';

const { status } = await Location.requestForegroundPermissionsAsync();
if (status !== 'granted') return;

const sub = await Location.watchPositionAsync(
  { accuracy: Location.Accuracy.BestForNavigation, timeInterval: 2000, distanceInterval: 5 },
  (pos) => addPoint(pos.coords.latitude, pos.coords.longitude)
);
// más tarde: sub.remove();
```

Para el mapa real (algo que la demo no podía hacer por no cargar mapas externos), usa `react-native-maps` con `MapView` y `Polyline`, mostrando el trazado en un mapa de verdad. Al finalizar, sube `points` a `activity_routes` y aplica `hide_start_end` recortando los primeros/últimos N metros antes de guardarlos si el usuario lo activó, igual que ya contempla la tabla.

## 6. Fotos: perfil, comidas, actividades y publicaciones

```ts
import * as ImagePicker from 'expo-image-picker';

const result = await ImagePicker.launchCameraAsync({ quality: 0.6 });
if (!result.canceled) {
  const file = result.assets[0];
  const path = `${user.id}/${Date.now()}.jpg`;
  await supabase.storage.from('meal-photos').upload(path, {
    uri: file.uri, type: 'image/jpeg', name: path,
  } as any);
  const { data } = supabase.storage.from('meal-photos').getPublicUrl(path);
  // guarda data.publicUrl en meals.photo_url
}
```

Crea los buckets (`avatars`, `covers`, `meal-photos`, `post-media`, `event-covers`, `community-media`) desde el panel de Supabase y copia la política del comentario al final de `runova_schema.sql`.

## 7. Escáner de alimentos con IA real

En la demo, el "análisis" era una simulación con una lista fija de platos. Para que sea real:

1. Sube la foto al bucket `meal-photos` como en el paso anterior.
2. Llama a un endpoint propio (una Edge Function de Supabase, no la app directamente) que reciba la URL de la imagen y llame a la API de OpenAI con capacidad de visión, pidiendo un JSON con alimentos detectados y macros estimados.
3. Devuelve ese JSON a la app y rellena el formulario de "Añadir comida" igual que hacía `useShot()` en la demo, dejando que el usuario edite antes de guardar.

Hazlo siempre desde una Edge Function (no desde el cliente) para no exponer tu clave de la API de OpenAI dentro de la app.

## 8. Chat de evento en tiempo real

La demo recargaba el chat manualmente tras cada mensaje. Con Supabase Realtime, se actualiza solo:

```ts
const channel = supabase
  .channel(`event-${eventId}`)
  .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'event_messages', filter: `event_id=eq.${eventId}` },
    (payload) => appendMessage(payload.new))
  .subscribe();
```

## 9. Notificaciones push

```bash
npx expo install expo-notifications expo-device
```

Guarda el `expoPushToken` del dispositivo en una columna de `profiles` o en una tabla `push_tokens`, y dispara los envíos desde una Edge Function cuando se inserte una fila en `notifications` (puedes usar un *database webhook* de Supabase para esto, sin que la app tenga que hacer nada extra).

## 10. Orden recomendado de desarrollo

Sigue la prioridad que ya definiste en el documento original:

1. **Semana 1-2:** Auth, perfil, feed de solo lectura, publicar texto.
2. **Semana 3:** Actividades manuales, nutrición, escáner con IA real.
3. **Semana 4:** Eventos, unirse/salir, chat de evento.
4. **Semana 5:** GPS en vivo con mapa real, fotos en todo el feed.
5. **Semana 6+:** Comunidades, retos, logros, notificaciones push, RUNOVA PRO con Stripe.

## 11. Publicar en las tiendas

Cuando tengas una versión estable:

```bash
npx eas build --platform ios
npx eas build --platform android
npx eas submit
```

Necesitarás cuenta de desarrollador de Apple (99 $/año) y de Google Play (25 $ pago único), además de preparar política de privacidad, icono y capturas, tal como ya anticipaste en tu documento original.

---

**Siguiente paso práctico:** abre Claude Code en la carpeta de tu nuevo proyecto Expo y pídele, pantalla por pantalla, que traduzca cada vista de `runova.html` a su equivalente en `app/`, empezando por el feed y la autenticación. Yo puedo seguir ayudándote aquí con decisiones de arquitectura, el esquema SQL, o revisando fragmentos de código que me pegues.
