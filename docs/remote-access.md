# Deck desde el celular

La interfaz web de deck controla agentes que ejecutan comandos en tu computador. Por eso solo escucha en `127.0.0.1` y se abre desde otros dispositivos a través de **Tailscale**, una red privada entre tus propios equipos. Nunca queda en internet.

## Preparar (una vez)

1. Corre `rune install` y marca **Acceso desde el celular (Tailscale)**. Instala Tailscale, te da permiso para manejar `tailscale serve` sin `sudo` y deja listo `rune remote`.
2. Conecta el PC: `sudo tailscale up` (abre el enlace e inicia sesión con tu cuenta personal).
3. Instala la app de Tailscale en el celular con **la misma cuenta**.
4. En el [panel de Tailscale](https://login.tailscale.com/admin/dns), activa **MagicDNS** y **HTTPS Certificates**.
5. Aplica la política de acceso de abajo.

## Usar

```bash
rune remote on        # publica deck en tu Tailscale y muestra la dirección https://….ts.net
rune remote pair      # código de un solo uso para un dispositivo nuevo (vence en 5 minutos)
rune remote status    # si está publicado y qué dispositivos tienen acceso
rune remote off       # deja de publicarlo
```

En el celular abre la dirección `https://….ts.net`. La primera vez pide un código: genéralo en el PC con `rune remote pair`. Después ese dispositivo queda recordado.

- **iPhone:** en Safari, **Compartir → Agregar a inicio**, abre el ícono y activa las notificaciones (la campana).
- **Android:** en Chrome, **Agregar a la pantalla principal** y activa las notificaciones.

El PC tiene que estar prendido con WSL corriendo. El celular es solo una ventana hacia él.

## Capas de seguridad

| Capa | Qué protege |
|---|---|
| Deck solo escucha en `127.0.0.1` | Nada fuera del PC llega directo a la página |
| `tailscale serve` y nunca Funnel | Solo tus dispositivos de Tailscale la alcanzan. `rune remote on` se niega a seguir si Funnel está encendido, y deck queda con `allowFunnel: false` |
| Código de emparejamiento (por defecto) | Aunque alguien entre a tu Tailscale, necesita un código generado en tu PC, de un solo uso y que vence en 5 minutos |
| `rune remote off` cuando no lo uses | La página solo está publicada mientras la necesitas |
| Aprobaciones en `relay` | Ningún agente corre comandos sin tu aprobación, también desde el celular. No actives YOLO en sesiones que vayas a manejar desde el celular |
| Política de acceso de Tailscale | Solo tus propios dispositivos se ven entre sí |
| Revocar | Si pierdes el celular: `rune remote devices`, `rune remote revoke <id>` y elimínalo en el panel de Tailscale |

`rune remote on --auto` quita el código: cualquier dispositivo de tu Tailscale entra directo. Es más cómodo y menos seguro; úsalo solo si nadie más tiene acceso a tu red de Tailscale.

Además:

- No desactives la expiración de claves de Tailscale (por defecto 180 días) en el PC.
- Ten bloqueo de pantalla con huella o rostro en el celular.
- No compartas este equipo con otros usuarios desde el panel de Tailscale.

## Política de acceso de Tailscale

En el panel, **Access controls**, reemplaza la política por esta. Cada usuario solo alcanza sus propios dispositivos, y solo al puerto 443 (HTTPS), que es el que usa deck:

```json
{
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["autogroup:self"],
      "ip": ["tcp:443"]
    }
  ],
  "ssh": []
}
```

Si más adelante usas Tailscale para otras cosas entre tus equipos (SSH, compartir archivos), cambia `"ip": ["tcp:443"]` por `"ip": ["*"]`: sigue limitado a tus propios dispositivos.
