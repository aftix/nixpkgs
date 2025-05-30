{
  lib,
  buildGoModule,
  rustPlatform,
  fetchFromGitHub,
  fetchpatch,
  makeWrapper,
  CoreFoundation,
  AppKit,
  binaryen,
  cargo,
  libfido2,
  nodejs,
  openssl,
  pkg-config,
  pnpm_10,
  rustc,
  Security,
  stdenv,
  xdg-utils,
  wasm-bindgen-cli,
  wasm-pack,
  nixosTests,

  withRdpClient ? true,

  version,
  hash,
  vendorHash,
  extPatches ? [ ],
  cargoHash,
  pnpmHash,
}:
let
  # This repo has a private submodule "e" which fetchgit cannot handle without failing.
  src = fetchFromGitHub {
    owner = "gravitational";
    repo = "teleport";
    rev = "v${version}";
    inherit hash;
  };
  pname = "teleport";
  inherit version;

  rdpClient = rustPlatform.buildRustPackage rec {
    pname = "teleport-rdpclient";
    useFetchCargoVendor = true;
    inherit cargoHash;
    inherit version src;

    buildAndTestSubdir = "lib/srv/desktop/rdp/rdpclient";

    buildInputs =
      [ openssl ]
      ++ lib.optionals stdenv.hostPlatform.isDarwin [
        CoreFoundation
        Security
      ];
    nativeBuildInputs = [ pkg-config ];

    # https://github.com/NixOS/nixpkgs/issues/161570 ,
    # buildRustPackage sets strictDeps = true;
    nativeCheckInputs = buildInputs;

    OPENSSL_NO_VENDOR = "1";

    postInstall = ''
      mkdir -p $out/include
      cp ${buildAndTestSubdir}/librdprs.h $out/include/
    '';
  };

  webassets = stdenv.mkDerivation {
    pname = "teleport-webassets";
    inherit src version;

    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit src;
      hash = cargoHash;
    };

    pnpmDeps = pnpm_10.fetchDeps {
      inherit src pname version;
      hash = pnpmHash;
    };

    nativeBuildInputs = [
      binaryen
      cargo
      nodejs
      pnpm_10.configHook
      rustc
      rustc.llvmPackages.lld
      rustPlatform.cargoSetupHook
      wasm-bindgen-cli
      wasm-pack
    ];

    patches = [
      (fetchpatch {
        name = "disable-wasm-opt-for-ironrdp.patch";
        url = "https://github.com/gravitational/teleport/commit/994890fb05360b166afd981312345a4cf01bc422.patch?full_index=1";
        hash = "sha256-Y5SVIUQsfi5qI28x5ccoRkBjpdpeYn0mQk8sLO644xo=";
      })
    ];

    configurePhase = ''
      runHook preConfigure

      export HOME=$(mktemp -d)

      runHook postConfigure
    '';

    buildPhase = ''
      PATH=$PATH:$PWD/node_modules/.bin

      pushd web/packages/teleport
      # https://github.com/gravitational/teleport/blob/6b91fe5bbb9e87db4c63d19f94ed4f7d0f9eba43/web/packages/teleport/README.md?plain=1#L18-L20
      RUST_MIN_STACK=16777216 wasm-pack build ./src/ironrdp --target web --mode no-install
      vite build
      popd
    '';

    installPhase = ''
      mkdir -p $out
      cp -R webassets/. $out
    '';
  };
in
buildGoModule rec {
  inherit pname src version;
  inherit vendorHash;
  proxyVendor = true;

  subPackages = [
    "tool/tbot"
    "tool/tctl"
    "tool/teleport"
    "tool/tsh"
  ];
  tags = [
    "libfido2"
    "webassets_embed"
  ] ++ lib.optional withRdpClient "desktop_access_rdp";

  buildInputs =
    [
      openssl
      libfido2
    ]
    ++ lib.optionals (stdenv.hostPlatform.isDarwin && withRdpClient) [
      CoreFoundation
      Security
      AppKit
    ];
  nativeBuildInputs = [
    makeWrapper
    pkg-config
  ];

  patches = extPatches ++ [
    ./0001-fix-add-nix-path-to-exec-env.patch
    ./rdpclient.patch
    ./tsh.patch
  ];

  # Reduce closure size for client machines
  outputs = [
    "out"
    "client"
  ];

  preBuild =
    ''
      cp -r ${webassets} webassets
    ''
    + lib.optionalString withRdpClient ''
      ln -s ${rdpClient}/lib/* lib/
      ln -s ${rdpClient}/include/* lib/srv/desktop/rdp/rdpclient/
    '';

  # Multiple tests fail in the build sandbox
  # due to trying to spawn nixbld's shell (/noshell), etc.
  doCheck = false;

  postInstall = ''
    mkdir -p $client/bin
    mv {$out,$client}/bin/tsh
    # make xdg-open overrideable at runtime
    wrapProgram $client/bin/tsh --suffix PATH : ${lib.makeBinPath [ xdg-utils ]}
    ln -s {$client,$out}/bin/tsh
  '';

  doInstallCheck = true;

  installCheckPhase = ''
    $out/bin/tsh version | grep ${version} > /dev/null
    $client/bin/tsh version | grep ${version} > /dev/null
    $out/bin/tbot version | grep ${version} > /dev/null
    $out/bin/tctl version | grep ${version} > /dev/null
    $out/bin/teleport version | grep ${version} > /dev/null
  '';

  passthru.tests = nixosTests.teleport;

  meta = with lib; {
    description = "Certificate authority and access plane for SSH, Kubernetes, web applications, and databases";
    homepage = "https://goteleport.com/";
    license = licenses.agpl3Plus;
    maintainers = with maintainers; [
      arianvp
      justinas
      sigma
      tomberek
      freezeboy
      techknowlogick
      juliusfreudenberger
    ];
    platforms = platforms.unix;
    # go-libfido2 is broken on platforms with less than 64-bit because it defines an array
    # which occupies more than 31 bits of address space.
    broken = stdenv.hostPlatform.parsed.cpu.bits < 64;
  };
}
