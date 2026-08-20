#!/usr/bin/env janet
###############################################################################
# build-kernel.janet
#
# Skrypt budujący jądro Linuksa ze źródeł dla dystrybucji Zenith Linux.
# Zakłada styl "Linux From Scratch": budowa odbywa się w chrooted środowisku,
# w którym są już dostępne: gcc, make, binutils, bc, flex, bison, perl,
# python3, openssl (nagłówki), oraz opcjonalnie cpio (dla initramfs).
#
# Użycie:
#   janet build-kernel.janet <komenda> [opcje]
#
# Komendy:
#   fetch        - pobiera i weryfikuje tarball źródeł jądra
#   extract      - rozpakowuje źródła
#   configure    - kopiuje/tworzy .config i uruchamia olddefconfig
#   build        - kompiluje jądro i moduły
#   modules      - instaluje moduły do $ZENITH_ROOT
#   install      - instaluje obraz jądra, System.map, .config do /boot
#   initramfs    - generuje initramfs (jeśli dostępny jest dracut/mkinitramfs)
#   all          - wykonuje wszystkie powyższe kroki po kolei
#   clean        - czyści drzewo źródeł (make mrproper)
#
# Zmienne środowiskowe (wszystkie mają sensowne wartości domyślne):
#   ZENITH_ROOT      - katalog docelowy systemu (domyślnie /mnt/zenith)
#   KERNEL_VERSION    - wersja jądra, np. 6.10.4
#   KERNEL_CONFIG     - ścieżka do gotowego pliku .config (opcjonalnie)
#   JOBS              - liczba równoległych zadań make (domyślnie liczba CPU)
###############################################################################

(def env* (os/environ))

(defn getenv [name default]
  (or (env* name) default))

(def zenith-root  (getenv "ZENITH_ROOT" "/mnt/zenith"))
(def kernel-ver   (getenv "KERNEL_VERSION" "6.10.4"))
(def kernel-major (first (string/split "." kernel-ver)))
(def kernel-config (getenv "KERNEL_CONFIG" ""))
(def jobs (getenv "JOBS" (string (os/cpu-count))))

(def sources-dir (string zenith-root "/sources"))
(def build-dir   (string sources-dir "/linux-" kernel-ver))
(def tarball     (string sources-dir "/linux-" kernel-ver ".tar.xz"))
(def kernel-url
  (string "https://cdn.kernel.org/pub/linux/kernel/v" kernel-major ".x/"
          "linux-" kernel-ver ".tar.xz"))

###############################################################################
# Narzędzia pomocnicze
###############################################################################

(defn sh
  "Uruchamia jedno polecenie powłoki. Przerywa skrypt, jeśli zwróci błąd."
  [cmd]
  (print "==> " cmd)
  (def code (os/execute ["/bin/sh" "-c" cmd] :p))
  (when (not= code 0)
    (eprint "Błąd: polecenie zakończyło się kodem wyjścia " code)
    (os/exit code)))

(defn ensure-dir [path]
  (sh (string "mkdir -p " path)))

(defn file-exists? [path]
  (not (nil? (os/stat path))))

###############################################################################
# Kroki budowania
###############################################################################

(defn step-fetch []
  (ensure-dir sources-dir)
  (if (file-exists? tarball)
    (print "Tarball już pobrany: " tarball)
    (do
      (print "Pobieranie jądra " kernel-ver " z " kernel-url)
      (sh (string "curl -L --fail -o " tarball " " kernel-url))
      # weryfikacja sumy kontrolnej, jeśli podano plik .sha256 obok skryptu
      (when (file-exists? (string tarball ".sha256"))
        (sh (string "sha256sum -c " tarball ".sha256"))))))

(defn step-extract []
  (unless (file-exists? tarball)
    (eprint "Brak tarballa " tarball ". Najpierw uruchom komendę 'fetch'.")
    (os/exit 1))
  (if (file-exists? build-dir)
    (print "Źródła już rozpakowane w " build-dir)
    (do
      (print "Rozpakowywanie źródeł jądra...")
      (sh (string "tar -xf " tarball " -C " sources-dir)))))

(defn step-configure []
  (unless (file-exists? build-dir)
    (eprint "Brak katalogu źródeł " build-dir ". Najpierw uruchom 'extract'.")
    (os/exit 1))
  (if (not= kernel-config "")
    (do
      (print "Kopiowanie dostarczonej konfiguracji: " kernel-config)
      (sh (string "cp -v " kernel-config " " build-dir "/.config")))
    (do
      (print "Brak KERNEL_CONFIG - generowanie domyślnej konfiguracji (defconfig)")
      (sh (string "make -C " build-dir " defconfig"))))
  (print "Dostrajanie konfiguracji do bieżących źródeł (olddefconfig)...")
  (sh (string "make -C " build-dir " olddefconfig")))

(defn step-build []
  (print "Kompilacja jądra i modułów (jobs=" jobs ")...")
  (sh (string "make -C " build-dir " -j" jobs)))

(defn step-modules []
  (ensure-dir zenith-root)
  (print "Instalacja modułów jądra do " zenith-root "...")
  (sh (string "make -C " build-dir
              " INSTALL_MOD_PATH=" zenith-root
              " modules_install")))

(defn step-install []
  (def boot-dir (string zenith-root "/boot"))
  (ensure-dir boot-dir)
  (def arch-image
    # ścieżka obrazu jądra zależna od architektury x86; dostosuj dla arm64/riscv itd.
    (string build-dir "/arch/x86/boot/bzImage"))
  (print "Instalacja obrazu jądra do " boot-dir "...")
  (sh (string "cp -v " arch-image " " boot-dir "/vmlinuz-" kernel-ver "-zenith"))
  (sh (string "cp -v " build-dir "/System.map " boot-dir "/System.map-" kernel-ver))
  (sh (string "cp -v " build-dir "/.config " boot-dir "/config-" kernel-ver)))

(defn step-initramfs []
  (def boot-dir (string zenith-root "/boot"))
  (cond
    (= 0 (os/execute ["/bin/sh" "-c" "command -v dracut"] :p))
    (sh (string "chroot " zenith-root " dracut --kver " kernel-ver
                " /boot/initramfs-" kernel-ver ".img"))

    (= 0 (os/execute ["/bin/sh" "-c" "command -v mkinitramfs"] :p))
    (sh (string "chroot " zenith-root " mkinitramfs -o /boot/initramfs-"
                kernel-ver ".img " kernel-ver))

    (do
      (print "Brak dracut/mkinitramfs w chroot - pomijam generowanie initramfs.")
      (print "Zainstaluj jeden z nich w Zenith Linux, jeśli initramfs jest potrzebny."))))

(defn step-clean []
  (when (file-exists? build-dir)
    (sh (string "make -C " build-dir " mrproper"))))

###############################################################################
# Dispatcher
###############################################################################

(def steps
  {"fetch"     step-fetch
   "extract"   step-extract
   "configure" step-configure
   "build"     step-build
   "modules"   step-modules
   "install"   step-install
   "initramfs" step-initramfs
   "clean"     step-clean})

(defn step-all []
  (step-fetch)
  (step-extract)
  (step-configure)
  (step-build)
  (step-modules)
  (step-install)
  (step-initramfs)
  (print "Budowa jądra " kernel-ver " dla Zenith Linux zakończona pomyślnie."))

(defn main [&]
  (def cmd (get (dyn :args) 1))
  (cond
    (nil? cmd)
    (do
      (print "Użycie: janet build-kernel.janet <fetch|extract|configure|build|modules|install|initramfs|all|clean>")
      (os/exit 1))

    (= cmd "all")
    (step-all)

    (get steps cmd)
    ((get steps cmd))

    (do
      (eprint "Nieznana komenda: " cmd)
      (os/exit 1))))
