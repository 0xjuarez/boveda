# boveda

Una bóveda cifrada de verdad para Linux, en un solo script de bash. Crea un
archivo contenedor cifrado con LUKS2 que se monta como una carpeta normal
cuando lo desbloqueas con tu contraseña, y que al cerrarlo vuelve a ser solo
ruido: sin la contraseña no se distingue de datos aleatorios.

## Requisitos

- Linux con `cryptsetup`, `losetup`, `mkfs.ext4`, `e2fsck`, `shred` y `sudo`.
- En Debian / Kali: `sudo apt install cryptsetup`

## Uso

```bash
chmod +x boveda.sh

./boveda.sh crear 1G       # crea ~/boveda.img de 1 GB (512M, 2G...)
./boveda.sh abrir           # pide la contraseña y monta la bóveda en ~/boveda
./boveda.sh cerrar          # desmonta y cierra la bóveda
./boveda.sh estado          # muestra si está abierta o cerrada
./boveda.sh respaldo        # guarda (o actualiza) el respaldo de la cabecera LUKS
./boveda.sh cambiar-clave   # cambia la contraseña de la bóveda
./boveda.sh borrar          # destruye la bóveda y su respaldo local (irreversible)
./boveda.sh restaurar       # restaura la cabecera desde el respaldo (emergencia)
./boveda.sh version         # muestra la versión
```

Guarda tus archivos en `~/boveda` mientras está abierta. Al cerrarla con
`cerrar`, el archivo `~/boveda.img` queda cifrado.

Se puede cambiar la ubicación del contenedor y del montaje con variables de
entorno:

```bash
BOVEDA_ARCHIVO=~/Documentos/mi-boveda.img BOVEDA_MONTAJE=~/secreto ./boveda.sh crear 2G
```

## Seguridad

- **La contraseña no se guarda en ningún lado.** El script exige mínimo 12
  caracteres y recomienda 16 o más. Si la pierdes, no hay forma de recuperar
  lo que hay dentro, ni con el respaldo de cabecera. Así funciona el cifrado
  real.
- **Respalda la cabecera.** Al crear la bóveda se guarda
  `~/boveda.header.bak`. Copia ese archivo a otro lugar (USB, otro disco).
  Si la cabecera del contenedor se daña, ese respaldo es la única forma de
  recuperar el acceso. Trátalo con el mismo cuidado que la bóveda: quien
  tenga el respaldo y tu contraseña puede abrirla.
- **Al abrir se revisa el sistema de archivos** con `e2fsck` antes de montar.
  Si encuentra errores que no puede reparar solo, la bóveda queda
  desbloqueada pero sin montar, y te dice cómo revisarla a mano.
- **Al montar se usan las opciones `nosuid,nodev`.** Nada de lo que haya
  dentro se ejecuta con privilegios elevados por accidente.
- **Borrar destruye de verdad.** El comando `borrar` sobrescribe el
  contenedor con datos aleatorios (3 pasadas con `shred`) antes de
  eliminarlo, en lugar de un `rm` que dejaría los datos recuperables.
- **Una sola operación a la vez.** El script usa un candado (`flock`) para
  que dos operaciones no se pisen entre sí.
- La contraseña se pasa a `cryptsetup` por tubería, nunca como argumento en
  la línea de comandos, y se borra de la memoria del script después de
  usarla.

## Cómo funciona

1. `crear` reserva un archivo del tamaño pedido con `fallocate` y lo cifra
   con `cryptsetup luksFormat` en LUKS2: AES-XTS con clave de 512 bits,
   SHA-512 y 2000 ms de iteración para la derivación de clave.
2. Guarda el respaldo de la cabecera con `luksHeaderBackup`.
3. Desbloquea el contenedor con un dispositivo loop, crea un sistema de
   archivos ext4 dentro y lo monta en `~/boveda`.
4. `abrir` repite el desbloqueo, revisa el sistema de archivos y monta.
5. `cerrar` desmonta, cierra el mapeo LUKS y suelta el loop.

## Licencia

MIT. Ver `LICENSE`.
