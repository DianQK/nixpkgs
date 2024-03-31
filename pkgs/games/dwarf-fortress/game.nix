{ stdenv
, lib
, fetchurl
, SDL
, SDL2
, SDL2_image
, SDL2_mixer
, fmodex
, dwarf-fortress-unfuck
, autoPatchelfHook

  # Our own "unfuck" libs for macOS
, ncurses
, gcc

, dfVersion
, df-hashes
}:

let
  inherit (lib)
    attrNames
    elemAt
    getAttr
    getLib
    hasAttr
    licenses
    maintainers
    makeLibraryPath
    optional
    optionals
    optionalString
    splitVersion
    toInt
    ;

  # Map Dwarf Fortress platform names to Nixpkgs platform names.
  # Other srcs are avilable like 32-bit mac & win, but I have only
  # included the ones most likely to be needed by Nixpkgs users.
  platforms = {
    x86_64-linux = "linux";
    i686-linux = "linux32";
    x86_64-darwin = "osx";
    i686-darwin = "osx32";
    x86_64-cygwin = "win";
    i686-cygwin = "win32";
  };

  dfVersionTuple = splitVersion dfVersion;
  dfVersionBaseIndex = let
    x = (builtins.length dfVersionTuple) - 2;
  in if x >= 0 then x else 0;
  baseVersion = toInt (elemAt dfVersionTuple dfVersionBaseIndex);
  patchVersion = elemAt dfVersionTuple (dfVersionBaseIndex + 1);

  isV50 = baseVersion >= 50;
  enableUnfuck = !isV50 && dwarf-fortress-unfuck != null;

  libpath = makeLibraryPath (
    [ stdenv.cc.cc stdenv.cc.libc ]
    ++ optional (!isV50) SDL
    ++ optional enableUnfuck dwarf-fortress-unfuck
  );

  game =
    if hasAttr dfVersion df-hashes
    then getAttr dfVersion df-hashes
    else throw "Unknown Dwarf Fortress version: ${dfVersion}";
  dfPlatform =
    if hasAttr stdenv.hostPlatform.system platforms
    then getAttr stdenv.hostPlatform.system platforms
    else throw "Unsupported system: ${stdenv.hostPlatform.system}";
  sha256 =
    if hasAttr dfPlatform game
    then getAttr dfPlatform game
    else throw "Unsupported dfPlatform: ${dfPlatform}";
  exe = if stdenv.isLinux then
    if baseVersion >= 50 then "dwarfort" else "libs/Dwarf_Fortress"
  else
    "dwarfort.exe";
in

stdenv.mkDerivation {
  pname = "dwarf-fortress";
  version = dfVersion;

  src = fetchurl {
    url = "https://www.bay12games.com/dwarves/df_${toString baseVersion}_${toString patchVersion}_${dfPlatform}.tar.bz2";
    inherit sha256;
  };

  sourceRoot = ".";

  postUnpack = optionalString stdenv.isLinux ''
    if [ -d df_linux ]; then
      mv df_linux/* .
    fi
  '' + optionalString stdenv.isDarwin ''
    if [ -d df_osx ]; then
      mv df_osx/* .
    fi
  '';

  nativeBuildInputs = optional isV50 autoPatchelfHook;
  buildInputs = optionals isV50 [ SDL2 SDL2_image SDL2_mixer stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall

    exe=$out/${exe}
    mkdir -p $out
    cp -r * $out

    # Lots of files are +x in the newer releases...
    find $out -type d -exec chmod 0755 {} \;
    find $out -type f -exec chmod 0644 {} \;
    chmod +x $exe
    [ -f $out/df ] && chmod +x $out/df
    [ -f $out/run_df ] && chmod +x $out/run_df

    # Store the original hash
    md5sum $exe | awk '{ print $1 }' > $out/hash.md5.orig
    echo "Original MD5: $(<$out/hash.md5.orig)" >&2
  '' + optionalString (!isV50 && stdenv.isLinux) ''
    rm -f $out/libs/*.so
    patchelf \
      --set-interpreter $(cat ${stdenv.cc}/nix-support/dynamic-linker) \
      --set-rpath "${libpath}" \
      $exe
  '' + optionalString stdenv.isDarwin ''
    # My custom unfucked dwarfort.exe for macOS. Can't use
    # absolute paths because original doesn't have enough
    # header space. Someone plz break into Tarn's house & put
    # -headerpad_max_install_names into his LDFLAGS.

    ln -s ${getLib ncurses}/lib/libncurses.dylib $out/libs
    ln -s ${getLib gcc.cc}/lib/libstdc++.6.dylib $out/libs
    ln -s ${getLib fmodex}/lib/libfmodex.dylib $out/libs

    install_name_tool \
      -change /usr/lib/libncurses.5.4.dylib \
              @executable_path/libs/libncurses.dylib \
      -change /usr/local/lib/x86_64/libstdc++.6.dylib \
              @executable_path/libs/libstdc++.6.dylib \
      $exe
  '' + ''
    ls -al $out
    runHook postInstall
  '';

  fixupPhase = ''
    runHook preFixup
    runHook postFixup

    # Store the new hash as the very last step.
    exe=$out/${exe}
    md5sum $exe | awk '{ print $1 }' > $out/hash.md5
    echo "Patched MD5: $(<$out/hash.md5)" >&2
  '';

  passthru = {
    inherit baseVersion patchVersion dfVersion exe;
    updateScript = ./update.sh;
  };

  meta = {
    description = "A single-player fantasy game with a randomly generated adventure world";
    homepage = "https://www.bay12games.com/dwarves/";
    license = licenses.unfreeRedistributable;
    platforms = attrNames platforms;
    maintainers = with maintainers; [ a1russell robbinch roconnor abbradar numinit shazow ncfavier ];
  };
}
