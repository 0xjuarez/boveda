#!/usr/bin/env bash
# boveda - una bóveda cifrada de verdad, con LUKS2 (AES-256-XTS)
#
# Uso:
#   ./boveda.sh crear [TAMAÑO]   crea ~/boveda.img (por defecto 1G, ej: 512M, 2G)
#   ./boveda.sh abrir             pide tu contraseña y monta la bóveda en ~/boveda
#   ./boveda.sh cerrar            desmonta y cierra la bóveda
#   ./boveda.sh estado            muestra si está abierta o cerrada
#   ./boveda.sh respaldo          guarda (o actualiza) el respaldo de la cabecera LUKS
#   ./boveda.sh cambiar-clave     cambia la contraseña de la bóveda
#   ./boveda.sh borrar            destruye la bóveda y su respaldo local (irreversible)
#   ./boveda.sh restaurar         restaura la cabecera desde el respaldo (emergencia)
#   ./boveda.sh version           muestra la versión
#
# Requisitos: cryptsetup, losetup, mkfs.ext4, e2fsck, shred, sudo
#   Debian / Kali:  sudo apt install cryptsetup
#
# La contraseña NO se guarda en ningún lado. Si la pierdes, no hay forma
# de recuperar lo que hay dentro. Así funciona el cifrado real.
# Mientras está cerrada, boveda.img es solo ruido: sin la contraseña no se
# distingue de datos aleatorios.
set -euo pipefail

VERSION="1.1.0"
VAULT_FILE="${BOVEDA_ARCHIVO:-$HOME/boveda.img}"
MOUNT_POINT="${BOVEDA_MONTAJE:-$HOME/boveda}"
HEADER_BAK="${VAULT_FILE%.img}.header.bak"
MAP_NAME="boveda"
MIN_CLAVE=12

# Evita dos operaciones a la vez sobre la misma bóveda
exec 9>"$HOME/.boveda.lock"
flock -n 9 || { echo "boveda: ya hay otra operación en curso" >&2; exit 1; }

die() { echo "boveda: $*" >&2; exit 1; }

necesito() {
  command -v "$1" >/dev/null 2>&1 || die "falta '$1'. En Debian/Kali: sudo apt install cryptsetup"
}

loop_de() {
  sudo losetup -j "$VAULT_FILE" 2>/dev/null | cut -d: -f1 | head -n1 || true
}

abierta() { [ -e "/dev/mapper/$MAP_NAME" ]; }

# Convierte "512M", "1G", "2G" o un número de bytes a bytes. Falla si el formato no vale.
a_bytes() {
  local s="${1^^}" n mult=1
  if [[ "$s" =~ ^([0-9]+)([KMG])?$ ]]; then
    n="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
      K) mult=1024 ;;
      M) mult=1048576 ;;
      G) mult=1073741824 ;;
    esac
    echo $(( n * mult ))
  else
    return 1
  fi
}

# Pide una contraseña nueva: mínimo 12 caracteres, dos veces, sin mostrarla.
# Queda en $CLAVE; se borra con unset después de usarla.
pedir_clave_nueva() {
  local c1 c2 resp
  while true; do
    read -rsp "Contraseña nueva (mínimo $MIN_CLAVE caracteres): " c1 || die "entrada cerrada"
    echo
    if [ "${#c1}" -lt "$MIN_CLAVE" ]; then
      echo "Muy corta: mínimo $MIN_CLAVE caracteres."
      continue
    fi
    if [ "${#c1}" -lt 16 ]; then
      read -rp "Tiene menos de 16 caracteres. Es usable pero débil. ¿Seguir con ella? [s/N] " resp || die "entrada cerrada"
      [[ "$resp" =~ ^[sS]$ ]] || continue
    fi
    read -rsp "Repite la contraseña: " c2 || die "entrada cerrada"
    echo
    if [ "$c1" != "$c2" ]; then
      echo "No coinciden. Inténtalo de nuevo."
      continue
    fi
    break
  done
  CLAVE="$c1"
  unset c1 c2
}

pedir_clave() {
  read -rsp "Contraseña de la bóveda: " CLAVE || die "entrada cerrada"
  echo
  [ -n "$CLAVE" ] || die "contraseña vacía"
}

cmd_crear() {
  local tam="${1:-1G}" bytes libre resp
  necesito cryptsetup; necesito losetup; necesito mkfs.ext4; necesito fallocate; necesito shred
  bytes="$(a_bytes "$tam")" || die "tamaño inválido: '$tam'. Usa algo como 512M, 1G o 2G."
  [ -e "$VAULT_FILE" ] && die "ya existe $VAULT_FILE. Bórralo primero si quieres crear otra (ojo: pierdes lo que haya dentro)."
  libre="$(df --output=avail -B1 "$HOME" | tail -n1 | tr -d ' ')"
  [ "$libre" -gt "$bytes" ] || die "no hay espacio suficiente en $HOME (libres: $(( libre / 1048576 )) MB, necesitas: $(( bytes / 1048576 )) MB)"
  read -rp "Voy a crear una bóveda de $tam en $VAULT_FILE. ¿Continuar? [s/N] " resp || die "entrada cerrada"
  [[ "$resp" =~ ^[sS]$ ]] || die "cancelado"
  pedir_clave_nueva
  echo "Creando el archivo..."
  fallocate -l "$bytes" "$VAULT_FILE"
  chmod 600 "$VAULT_FILE"
  if ! printf '%s' "$CLAVE" | sudo cryptsetup luksFormat --batch-mode --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 2000 \
    --key-file - "$VAULT_FILE"; then
    rm -f "$VAULT_FILE"
    unset CLAVE
    die "no se pudo cifrar el archivo. No quedó ningún resto."
  fi
  echo "Bóveda cifrada."
  cmd_respaldo
  echo "Creando el sistema de archivos dentro..."
  _abrir_mapper
  unset CLAVE
  sudo mkfs.ext4 -q -L boveda "/dev/mapper/$MAP_NAME"
  _montar
  echo
  echo "Listo. Tu bóveda está en $MOUNT_POINT"
  echo "Guarda ahí lo que quieras proteger y ciérrala con:  ./boveda.sh cerrar"
}

# Desbloquea la bóveda (sin montar). Si algo falla, suelta el loop.
# Usa $CLAVE si ya está puesta (al crearla); si no, la pide.
_abrir_mapper() {
  if abierta; then
    echo "La bóveda ya está abierta."
    return 0
  fi
  local loop
  loop="$(sudo losetup -f --show "$VAULT_FILE")"
  if [ -z "${CLAVE:-}" ]; then
    pedir_clave
  fi
  printf '%s' "$CLAVE" | sudo cryptsetup open "$loop" "$MAP_NAME" --key-file - \
    || { echo "Contraseña incorrecta o la bóveda está dañada." >&2; sudo losetup -d "$loop"; unset CLAVE; exit 1; }
  echo "Bóveda desbloqueada."
}

_montar() {
  mkdir -p "$MOUNT_POINT"
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "Ya estaba montada en $MOUNT_POINT"
  else
    sudo mount -o nosuid,nodev "/dev/mapper/$MAP_NAME" "$MOUNT_POINT"
    sudo chown "$USER:$USER" "$MOUNT_POINT"
    echo "Montada en $MOUNT_POINT"
  fi
}

cmd_abrir() {
  local rc=0
  necesito cryptsetup; necesito losetup; necesito e2fsck
  [ -e "$VAULT_FILE" ] || die "no existe $VAULT_FILE. Créala primero con: ./boveda.sh crear [TAMAÑO]"
  _abrir_mapper
  unset CLAVE
  echo "Revisando el sistema de archivos..."
  sudo e2fsck -p "/dev/mapper/$MAP_NAME" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "boveda: el sistema de archivos tiene errores que no se pudieron reparar solo." >&2
    echo "La bóveda quedó desbloqueada pero SIN montar. Revísala con:" >&2
    echo "  sudo e2fsck -f /dev/mapper/$MAP_NAME" >&2
    echo "Y luego monta con:  $0 abrir" >&2
    exit 1
  fi
  _montar
}

cmd_cerrar() {
  necesito cryptsetup; necesito losetup
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    sudo umount "$MOUNT_POINT" || die "no se pudo desmontar. Cierra los programas que estén usando $MOUNT_POINT y reintenta."
  fi
  if abierta; then
    sudo cryptsetup close "$MAP_NAME"
  fi
  local loop
  loop="$(loop_de)"
  [ -n "$loop" ] && sudo losetup -d "$loop" || true
  echo "Bóveda cerrada. $VAULT_FILE ahora es solo ruido cifrado."
}

cmd_estado() {
  if abierta; then
    echo "ABIERTA"
    sudo cryptsetup status "$MAP_NAME" 2>/dev/null | grep -E 'type:|cipher:|keysize:' || true
    mountpoint -q "$MOUNT_POINT" 2>/dev/null && echo "Montada en: $MOUNT_POINT" || echo "No montada (desbloqueada pero sin montar)."
  else
    if [ -e "$VAULT_FILE" ]; then
      echo "CERRADA - $VAULT_FILE ($(du -h "$VAULT_FILE" | cut -f1))"
    else
      echo "No existe ninguna bóveda. Créala con: ./boveda.sh crear [TAMAÑO]"
    fi
  fi
  if [ -e "$HEADER_BAK" ]; then
    echo "Respaldo de cabecera: $HEADER_BAK"
  else
    echo "Respaldo de cabecera: NO EXISTE (corre: $0 respaldo)"
  fi
}

cmd_respaldo() {
  local resp
  necesito cryptsetup
  [ -e "$VAULT_FILE" ] || die "no existe $VAULT_FILE. Créala primero con: ./boveda.sh crear [TAMAÑO]"
  if [ -e "$HEADER_BAK" ]; then
    read -rp "Ya existe $HEADER_BAK. ¿Sobrescribirlo? [s/N] " resp || die "entrada cerrada"
    [[ "$resp" =~ ^[sS]$ ]] || die "cancelado"
  fi
  sudo cryptsetup luksHeaderBackup "$VAULT_FILE" --header-backup-file "$HEADER_BAK"
  chmod 600 "$HEADER_BAK"
  echo "Respaldo de cabecera guardado en $HEADER_BAK"
  echo "Copia ese archivo a otro lugar (USB, otro disco). Sin él, si la cabecera se daña, pierdes todo aunque recuerdes la contraseña."
}

cmd_cambiar_clave() {
  local loop
  necesito cryptsetup; necesito losetup
  [ -e "$VAULT_FILE" ] || die "no existe $VAULT_FILE. Créala primero con: ./boveda.sh crear [TAMAÑO]"
  abierta && die "la bóveda está abierta. Ciérrala primero con: $0 cerrar"
  loop="$(sudo losetup -f --show "$VAULT_FILE")"
  echo "Te pedirá la contraseña actual y luego la nueva (dos veces)."
  sudo cryptsetup luksChangeKey "$loop" || { sudo losetup -d "$loop"; exit 1; }
  sudo losetup -d "$loop"
  echo "Contraseña cambiada. La anterior ya no funciona."
}

cmd_borrar() {
  local resp
  necesito shred
  [ -e "$VAULT_FILE" ] || die "no existe $VAULT_FILE. No hay nada que borrar."
  echo "ADVERTENCIA: esto destruye la bóveda y su respaldo local. No hay vuelta atrás."
  read -rp "Escribe BORRAR para confirmar: " resp || die "entrada cerrada"
  [ "$resp" = "BORRAR" ] || die "cancelado"
  if abierta || mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "Cerrando la bóveda primero..."
    cmd_cerrar
  fi
  echo "Sobrescribiendo $VAULT_FILE con datos aleatorios (3 pasadas)..."
  shred -u -n 3 "$VAULT_FILE"
  if [ -e "$HEADER_BAK" ]; then
    shred -u -n 3 "$HEADER_BAK"
  fi
  rmdir "$MOUNT_POINT" 2>/dev/null || true
  echo "Bóveda destruida. Si tienes copias del respaldo de cabecera en otro lugar, bórralas también."
}

cmd_restaurar() {
  local resp
  necesito cryptsetup
  [ -e "$HEADER_BAK" ] || die "no existe $HEADER_BAK. Sin respaldo no se puede restaurar la cabecera."
  abierta && die "la bóveda está abierta. Ciérrala primero con: $0 cerrar"
  echo "ADVERTENCIA: esto sobrescribe la cabecera de $VAULT_FILE con $HEADER_BAK."
  echo "Si el respaldo no es de esta bóveda, la dejas inservible."
  read -rp "Escribe RESTAURAR para confirmar: " resp || die "entrada cerrada"
  [ "$resp" = "RESTAURAR" ] || die "cancelado"
  sudo cryptsetup luksHeaderRestore "$VAULT_FILE" --header-backup-file "$HEADER_BAK"
  echo "Cabecera restaurada. Prueba abrir con: $0 abrir"
}

uso() {
  echo "boveda $VERSION - bóveda cifrada con LUKS2"
  echo "Uso: $0 {crear [TAMAÑO]|abrir|cerrar|estado|respaldo|cambiar-clave|borrar|restaurar|version}"
  echo "Ej: $0 crear 2G"
}

case "${1:-}" in
  crear)         cmd_crear "${2:-1G}" ;;
  abrir)         cmd_abrir ;;
  cerrar)        cmd_cerrar ;;
  estado)        cmd_estado ;;
  respaldo)      cmd_respaldo ;;
  cambiar-clave) cmd_cambiar_clave ;;
  borrar)        cmd_borrar ;;
  restaurar)     cmd_restaurar ;;
  version)       echo "boveda $VERSION" ;;
  *)             uso; exit 1 ;;
esac
