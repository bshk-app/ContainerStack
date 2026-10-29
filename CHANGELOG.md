# Changelog

All notable changes to ContainerStack are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This file is the single source of truth for release notes: the section matching
`VERSION` becomes both the Sparkle update description and the GitHub release
body. A publish with no matching section is refused.

release-please drafts each section from conventional commits and opens a release
PR. Those lines are commit subjects; rewrite them in the PR into what a user
should read in an update panel. Notes jotted under `## [Unreleased]` between
releases belong in that section — move them there while reviewing.

## [0.9.0](https://github.com/bshk-app/ContainerStack/compare/v0.8.1...v0.9.0) (2026-10-29)


### Added

* **a11y:** label the icon-only row action buttons ([fede7a7](https://github.com/bshk-app/ContainerStack/commit/fede7a7034b1df7e84000f21a44e28c4fa662a93))
* **a11y:** label the icon-only row action buttons ([5f615ee](https://github.com/bshk-app/ContainerStack/commit/5f615ee6bfd02c286289a88431e47456519840f1))
* **app:** add Doctor diagnostics to the sidebar ([40704f4](https://github.com/bshk-app/ContainerStack/commit/40704f4281a70c5e4cadc84edfda655601717c58))
* **app:** decide which runtime operation runs in one queue ([#102](https://github.com/bshk-app/ContainerStack/issues/102)) ([2baef33](https://github.com/bshk-app/ContainerStack/commit/2baef3335baa40d37ce49b6322ca66d828c0c512))
* **app:** draw the sidebar as a native source list ([fcf9aac](https://github.com/bshk-app/ContainerStack/commit/fcf9aac2535c4e37786631b717f7ebfc639e8114))
* **app:** run Start, Stop and Restart through one queue ([#102](https://github.com/bshk-app/ContainerStack/issues/102)) ([99bad42](https://github.com/bshk-app/ContainerStack/commit/99bad42cff4221c953398427847f6998e9e637d6))
* **app:** show containers, images, volumes, networks and stacks in native lists ([3db9ae4](https://github.com/bshk-app/ContainerStack/commit/3db9ae48583828cd4da824163a8de677e37e524c))
* **app:** use native lists and fix UI defects ([22c9be5](https://github.com/bshk-app/ContainerStack/commit/22c9be5db52197d2a7ac10cea94beb3620448e25))
* **core:** add DiagnosticRunner returning one check per request ([7dcf9a9](https://github.com/bshk-app/ContainerStack/commit/7dcf9a96d5b3a7935c30af9a0a736ac35249ddc9))
* **core:** add SystemProbe and its test fakes ([51e18ec](https://github.com/bshk-app/ContainerStack/commit/51e18ec6230b9b345ff7a772a0596d562ae90c60))
* **core:** add the DiagnosticReport value types ([44933a0](https://github.com/bshk-app/ContainerStack/commit/44933a023307071e0c7b18cea3b95034378515e7))
* **core:** bound the whole run, and run the probes at once ([d2fc5ac](https://github.com/bshk-app/ContainerStack/commit/d2fc5ac44798c3f97a2438f54f3447b7598838d6))
* **core:** derive a report verdict so a degraded run is observable (F-013) ([6505ee6](https://github.com/bshk-app/ContainerStack/commit/6505ee6048723ae5aac536dcd2c2e08dc431afa5))
* **core:** give the app-root check the CLI's own wording ([9a2a04c](https://github.com/bshk-app/ContainerStack/commit/9a2a04cf840bf528ded6024f765bdf7d4d9de98b))
* **core:** keep a proven over-commitment amber through a partial inspect ([9353ee8](https://github.com/bshk-app/ContainerStack/commit/9353ee88ea38793818956f6397c9715141b1b831))
* **core:** measure memory commitment for the CLI, and make the UI never pay for it ([f5f554d](https://github.com/bshk-app/ContainerStack/commit/f5f554deb947c55e7f346a17cd8b45578892f4e7))
* **core:** name the CLI and UI check sets, membership pinned by test ([2efc759](https://github.com/bshk-app/ContainerStack/commit/2efc75995a424633b014c266f2ce8029770325d2))
* **core:** project RuntimeState onto check verdicts ([2504561](https://github.com/bshk-app/ContainerStack/commit/25045614241d3a494a8bad34fe54f8177479b641))
* **core:** render a report as the CLI's own doctor text (F-003, F-012) ([731afca](https://github.com/bshk-app/ContainerStack/commit/731afcadfb60f0bb25e8216b87a8155532b09caf))
* **core:** report a wedged socket instead of outlasting it ([e95622c](https://github.com/bshk-app/ContainerStack/commit/e95622c3ada6fb4779cc31853a10e7ccc98245d0))
* **core:** report who holds the Docker socket, and never guess it is us ([13af038](https://github.com/bshk-app/ContainerStack/commit/13af038a54cbd28ef30af5a048d94a8c5f855d73))
* **core:** run diagnostic probes without swallowing failure ([55064dd](https://github.com/bshk-app/ContainerStack/commit/55064ddbc985e9678899b6aed4ad59af9ef43d27))
* **core:** tell an unroutable network from a table nobody could read ([f26cc53](https://github.com/bshk-app/ContainerStack/commit/f26cc534b82f77826482a923c96ae540e9dc45fb))
* **core:** time each check and log what the budget cut off (NFR-005) ([d31029b](https://github.com/bshk-app/ContainerStack/commit/d31029b83a9a9c5e247e048e6082b15fe4e9fc02))
* **doctor:** report the host memory running containers have claimed ([0433e22](https://github.com/bshk-app/ContainerStack/commit/0433e2249fabcf02b612dca29ec101191751c5a3))
* **doctor:** report the host memory running containers have claimed ([4aa229f](https://github.com/bshk-app/ContainerStack/commit/4aa229f973545cd8a11db994c192531531b3a311))
* publish ContainerStack 0.1.0 source snapshot ([85e97c2](https://github.com/bshk-app/ContainerStack/commit/85e97c2c07125fc46f49162b54f71525311510aa))
* **release:** move Sparkle enclosures to GitHub assets ([e1e13ca](https://github.com/bshk-app/ContainerStack/commit/e1e13ca8a332f7bc8eba5b3f0ffac70dfb077b1c))
* **release:** serve updates from GitHub, drop the release server ([eed5e96](https://github.com/bshk-app/ContainerStack/commit/eed5e9646f224079669dc892da820d2e48583208))
* **runtime:** say which Apple Container version is wrong, before starting ([8e0bf43](https://github.com/bshk-app/ContainerStack/commit/8e0bf4356d29781cf9bc93f55228b6f90d0fec5a))
* **runtime:** say which Apple Container version is wrong, before starting ([93cd193](https://github.com/bshk-app/ContainerStack/commit/93cd1938283bc7b103876b8a187b16a04d17a9f6))
* **sidebar:** let users hide resource sections they do not use ([57616b7](https://github.com/bshk-app/ContainerStack/commit/57616b7fdac4a2aa1798018ecafad036604c1c26))
* **sidebar:** let users hide resource sections they do not use ([803f71a](https://github.com/bshk-app/ContainerStack/commit/803f71a11684e6e4a591f932f60dad616642901b))
* **ui:** container resource limits with per-run overrides ([f69d864](https://github.com/bshk-app/ContainerStack/commit/f69d8646d630bd1373f4ef06d91787446bba1d0e))
* **updates:** ship the updater the bundle already advertised ([b2f0d61](https://github.com/bshk-app/ContainerStack/commit/b2f0d612f97d48c76057cb23771c8bbe2f13ffea))
* **updates:** ship the updater the bundle already advertised ([c02f491](https://github.com/bshk-app/ContainerStack/commit/c02f49116e014d8913f1902e3cea8e23e25355c7))


### Fixed

* **a11y:** give every icon action a contextual name ([b151eb9](https://github.com/bshk-app/ContainerStack/commit/b151eb94adcfec719ad175bb362762b1575ad102))
* **app:** apply the inventory epoch guard to two more stale-call races ([#70](https://github.com/bshk-app/ContainerStack/issues/70)) ([7ff94e7](https://github.com/bshk-app/ContainerStack/commit/7ff94e72d9af4b59a9334a16c060105dd8926cf8))
* **app:** apply the inventory epoch guard to two more stale-call races ([#70](https://github.com/bshk-app/ContainerStack/issues/70)) ([56a6dcb](https://github.com/bshk-app/ContainerStack/commit/56a6dcb362c0f15e184b5815a34f0ae536c1dabf))
* **app:** call the overview section Overview in the sidebar ([bce6e5e](https://github.com/bshk-app/ContainerStack/commit/bce6e5e4beaea80a7e1f4812108e9043cf4f7764))
* **app:** carry one attempt number through the whole start path ([f31eb4a](https://github.com/bshk-app/ContainerStack/commit/f31eb4a3138d3ad5bfb23a8ed37737196988c8e7))
* **app:** clear the liveness filter whenever health is published ([1708051](https://github.com/bshk-app/ContainerStack/commit/1708051b80ed9e5a3e1a458860701e6fa80490ff))
* **app:** draw selected rows with the system selection color ([c574f99](https://github.com/bshk-app/ContainerStack/commit/c574f9934537f275871c7a61a3d9f841b713e7c8))
* **app:** drop the inventory a failed runtime described ([6055e63](https://github.com/bshk-app/ContainerStack/commit/6055e632110a36c29562c78a3fd1d2bb07071540))
* **app:** drop the inventory a failed runtime described ([ac76c13](https://github.com/bshk-app/ContainerStack/commit/ac76c13c5cfddc212c632ad74b2a8f631112b362)), closes [#39](https://github.com/bshk-app/ContainerStack/issues/39)
* **app:** drop the volume Used by row that always read a dash ([d298d94](https://github.com/bshk-app/ContainerStack/commit/d298d9488080931e6a8ff1fcacee91211268e015))
* **app:** finish the class — stack statuses and the startup probes ([d32a26e](https://github.com/bshk-app/ContainerStack/commit/d32a26e6c138932912de663efb9cf4ee7d43cc90))
* **app:** fit published ports into the container row ([741d543](https://github.com/bshk-app/ContainerStack/commit/741d5435312e5a1e5cdc9a1eabb1a9ce306323ec))
* **app:** fit the sidebar's starting spinner in its slot ([d2e191b](https://github.com/bshk-app/ContainerStack/commit/d2e191bb9e7236a0c77809b81107c931e1a50d16))
* **app:** focus lists on click and give the inspector its own column ([b67cf10](https://github.com/bshk-app/ContainerStack/commit/b67cf1004b9aec9757180f8a5e31ca1ccb831f48))
* **app:** follow the core socket configuration ([dfff9c0](https://github.com/bshk-app/ContainerStack/commit/dfff9c0f91dc7c34231c6b4e66ebc736cd04e7f2))
* **app:** give a list keyboard focus when the user clicks it ([4eb74e7](https://github.com/bshk-app/ContainerStack/commit/4eb74e7ecff3b0c4be915c1ba68f6fe0ab60d3d2))
* **app:** give the inspector its own column and toolbar area ([17b17be](https://github.com/bshk-app/ContainerStack/commit/17b17be4a4ab351c65c6403eedfaff1c9a9dbafe))
* **app:** keep a container's avatar tint across launches ([7079aad](https://github.com/bshk-app/ContainerStack/commit/7079aad4a5fa0fc58036622c4907a112a2bcc26a))
* **app:** keep a probe begun during a Stop from restarting after it ([4bfc78f](https://github.com/bshk-app/ContainerStack/commit/4bfc78f76b288c314f537588fd3c173d0932b437))
* **app:** keep a Stop from being undone by work that started before it ([2e89bf2](https://github.com/bshk-app/ContainerStack/commit/2e89bf2384dd194edf1ddce5aab9233f52fdb20d))
* **app:** keep reads working while mutations are refused ([2358ed6](https://github.com/bshk-app/ContainerStack/commit/2358ed613ddd017509e0898f932c57c6ce56d953))
* **app:** keep reads working while mutations are refused ([68025e1](https://github.com/bshk-app/ContainerStack/commit/68025e139dfe3e748ccba4a7bad993a0ad0979f5))
* **app:** keep tests away from the user's Docker configuration ([#102](https://github.com/bshk-app/ContainerStack/issues/102)) ([dfe2d0d](https://github.com/bshk-app/ContainerStack/commit/dfe2d0d9faa57604fb2baa4b54bb11f44de5add1))
* **app:** keep the runtime poll running after the window closes ([024eb8f](https://github.com/bshk-app/ContainerStack/commit/024eb8f54d042544342a81d07c2cd4f31cb0237d))
* **app:** keep the runtime poll running after the window closes ([dafda6f](https://github.com/bshk-app/ContainerStack/commit/dafda6f13bd72eb68aba974e1fb7b95e72e1d7a2)), closes [#61](https://github.com/bshk-app/ContainerStack/issues/61)
* **app:** leave the context read to an adoption while one runs ([19a9abd](https://github.com/bshk-app/ContainerStack/commit/19a9abd164552791e483c4b0c97c8284bc95f868))
* **app:** let an explicit runtime failure outrank Starting ([897744b](https://github.com/bshk-app/ContainerStack/commit/897744b38fc11fa7ffe8dc36c0b48c622bc564ae))
* **app:** let an explicit runtime failure outrank Starting ([965d945](https://github.com/bshk-app/ContainerStack/commit/965d945c075367ffcdeae4b3100da601a070219d)), closes [#44](https://github.com/bshk-app/ContainerStack/issues/44)
* **app:** let an overtaken context adoption leave the decision to the newer read ([0cd56ca](https://github.com/bshk-app/ContainerStack/commit/0cd56ca1dbe31b8a1b4460e6560831fdf8dd8957))
* **app:** let Restart claim a start attempt only when it spawns a helper ([4eb363a](https://github.com/bshk-app/ContainerStack/commit/4eb363a4136556476c218497f6cabfec7f3c6b01))
* **app:** let Stop and Start own the helper the app launched ([9bdfe3e](https://github.com/bshk-app/ContainerStack/commit/9bdfe3e053948820892aca9bd1acf53030c75de7))
* **app:** let Stop and Start own the helper the app launched ([2e05c76](https://github.com/bshk-app/ContainerStack/commit/2e05c76f1a892c2d42d166fdd2d1bc360c79e868)), closes [#70](https://github.com/bshk-app/ContainerStack/issues/70) [#71](https://github.com/bshk-app/ContainerStack/issues/71)
* **app:** let the whole group header expand and collapse its group ([7ea0899](https://github.com/bshk-app/ContainerStack/commit/7ea08994228b2eaed15b53a003521c4de8c597e0))
* **app:** make an unresolved Lucide asset loud instead of blank ([0df025a](https://github.com/bshk-app/ContainerStack/commit/0df025a4415406833d9606e9bfa8f5f579fec3d4))
* **app:** make an unresolved Lucide asset loud instead of blank ([bd52beb](https://github.com/bshk-app/ContainerStack/commit/bd52beb2512eb9ad57fe0b9d0e597b53b840a285)), closes [#14](https://github.com/bshk-app/ContainerStack/issues/14)
* **app:** make Create the default button of the New Stack sheet ([a6984ed](https://github.com/bshk-app/ContainerStack/commit/a6984edc57020b3d378bccc54de9445eab94add1))
* **app:** make inspector actions and status pills readable in light mode ([bbc4c23](https://github.com/bshk-app/ContainerStack/commit/bbc4c2385b13d526ca3ae506616dc63c1487e8aa))
* **app:** make Start prominent only while a stack service is stopped ([311ca76](https://github.com/bshk-app/ContainerStack/commit/311ca76501a81e31f4320af8847a99472b434ab2))
* **app:** make the toolbar Run button run a container ([bb58eb0](https://github.com/bshk-app/ContainerStack/commit/bb58eb0bb1498128c8c5630d161a0cd53b06c4c0))
* **app:** name the app in the menu bar Quit item and add Command-Q ([a22f1c9](https://github.com/bshk-app/ContainerStack/commit/a22f1c9c4f077a18e97a0cb4a7b04722f4c12db9))
* **app:** name the first inspector tab Info and draw the tabs natively ([2772ed1](https://github.com/bshk-app/ContainerStack/commit/2772ed17291f20439d25e9859aeab2af58f7da7a))
* **app:** name the toolbar More menu for VoiceOver ([77e8d17](https://github.com/bshk-app/ContainerStack/commit/77e8d1779eae74dbf3edf07e943ed3b64a5621d8))
* **app:** number start attempts, and ask no recovery for a stopped runtime ([65df520](https://github.com/bshk-app/ContainerStack/commit/65df52073918544b3b0a553636827ba7ca4e3900))
* **app:** one unanswered probe no longer declares the runtime dead ([7b046b0](https://github.com/bshk-app/ContainerStack/commit/7b046b006938a94dc9166efab71d8be4a1b11789))
* **app:** one unanswered probe no longer declares the runtime dead ([d26cd66](https://github.com/bshk-app/ContainerStack/commit/d26cd66a4311a7f16c7a755afd1358b679d7f85f))
* **app:** open a recent container from Overview in Containers ([2f28966](https://github.com/bshk-app/ContainerStack/commit/2f289666df02536cac982944f19d4bbd95fb0515))
* **app:** open container logs at the newest line ([05405d2](https://github.com/bshk-app/ContainerStack/commit/05405d236f540e9cd01c8ee310faf2bfa5a1468d))
* **app:** open the stack editor from a stack row's context menu ([38b2e14](https://github.com/bshk-app/ContainerStack/commit/38b2e144ce974e8c02aede25ea48d1d2306c41a6))
* **app:** publish a refresh's lists under the epoch it began with ([#102](https://github.com/bshk-app/ContainerStack/issues/102)) ([650e10b](https://github.com/bshk-app/ContainerStack/commit/650e10b5a2e550acc840029a88237a911916703d))
* **app:** re-check the epoch before publishing a socket as responding ([0b423d8](https://github.com/bshk-app/ContainerStack/commit/0b423d80e3d243a8c5b69ae7383dd45825330c94))
* **app:** read the container version off the main actor ([ab2b119](https://github.com/bshk-app/ContainerStack/commit/ab2b119326f63cc660e8a6a5d37f24f0cf90308e))
* **app:** read the Docker context inside the monitor tick, window open only ([02cfc71](https://github.com/bshk-app/ContainerStack/commit/02cfc71b5f633f603bbda89a1d212182777e12fc))
* **app:** recognize ComposeRunner's own error shape, resolve resourceMessage too ([28a89bc](https://github.com/bshk-app/ContainerStack/commit/28a89bc1ded218976d03c9170b3beb66250cfbed))
* **app:** resolve only the messages that announced a runtime check ([0fdf119](https://github.com/bshk-app/ContainerStack/commit/0fdf1192da25d6f41217f93354e3b3c3d2559745))
* **app:** route group stop and stack down through the XPC-recovery hook ([aadcc36](https://github.com/bshk-app/ContainerStack/commit/aadcc361779bbaca077b1c2c4457639f1c6ed777))
* **app:** route group stop and stack down through the XPC-recovery hook ([86b0f06](https://github.com/bshk-app/ContainerStack/commit/86b0f061e8cf6129aff5cd847c5a5aac3099b0c2))
* **app:** run one context adoption at a time, each on a read nothing overtook ([193fd00](https://github.com/bshk-app/ContainerStack/commit/193fd0091b574866d7f788ee77b02f11e337ff2d))
* **app:** settle a leftover runtime check by the runtime's state ([9d04b8f](https://github.com/bshk-app/ContainerStack/commit/9d04b8fed350c81f5e4ee5ca44d79303590afb22))
* **app:** stop a dead runtime's inventory and health surviving its death ([cc45b09](https://github.com/bshk-app/ContainerStack/commit/cc45b0960a270e504187176acacefbc83675343d))
* **app:** stop an in-flight refresh resurrecting cleared inventory ([3b27ecc](https://github.com/bshk-app/ContainerStack/commit/3b27eccb8ae9f386d6190aa7e19633e4c357ede9)), closes [#43](https://github.com/bshk-app/ContainerStack/issues/43)
* **app:** take image avatar initials from the repository name ([75fb51b](https://github.com/bshk-app/ContainerStack/commit/75fb51b7bccef9a21908c343803a1e96e6a6c6aa))
* **cask:** boot out the runtime LaunchAgent on uninstall ([1e19b3f](https://github.com/bshk-app/ContainerStack/commit/1e19b3fb6028a6a86b7d46197d76feefb1f56c5c))
* **cask:** boot out the runtime LaunchAgent on uninstall ([22b7c4e](https://github.com/bshk-app/ContainerStack/commit/22b7c4ed2f904ec9aef918f762e9a45f096c41ec))
* **ci:** fail the release when the Sparkle pin leaves the linked version ([f47f83c](https://github.com/bshk-app/ContainerStack/commit/f47f83c5a4ac31048d9fcf57342f45f2e28b9081))
* **ci:** repair the invalid release workflow and lint for the cause ([b3710a7](https://github.com/bshk-app/ContainerStack/commit/b3710a78048b5f50616e0538a35440b9452be40a))
* **ci:** take the Sparkle tools from GitHub instead of the Homebrew cask ([d30b86e](https://github.com/bshk-app/ContainerStack/commit/d30b86ef651b4b351206ed9c2ae8cf4581e31b71))
* **ci:** take the Sparkle tools from GitHub instead of the Homebrew cask ([c79766d](https://github.com/bshk-app/ContainerStack/commit/c79766d9ca90c4ef81b276788d6362f701d2c0d7))
* **cli:** do not treat a missing routing table as NO ROUTE ([740ab2d](https://github.com/bshk-app/ContainerStack/commit/740ab2df7765d64f1928e7a3bb7d3027e454a0e6))
* **cli:** do not treat a missing routing table as NO ROUTE ([9c59866](https://github.com/bshk-app/ContainerStack/commit/9c598665099e9bc70d5ea61fc3e12715d2c21c2f))
* **cli:** judge only the networks a published port depends on ([6d06092](https://github.com/bshk-app/ContainerStack/commit/6d06092df70872f64967b4d5a325244442bfbf19))
* **cli:** judge only the networks a published port depends on ([5a5202e](https://github.com/bshk-app/ContainerStack/commit/5a5202e3afc0a61e7cb4e6bbe2d048c8409862c8)), closes [#36](https://github.com/bshk-app/ContainerStack/issues/36)
* **cli:** tell "nothing publishes" apart from "nothing could be checked" ([31a02f0](https://github.com/bshk-app/ContainerStack/commit/31a02f00955e282823614977943d5a1b56ecbed5))
* **cli:** tell "nothing publishes" apart from "nothing could be checked" ([bd89318](https://github.com/bshk-app/ContainerStack/commit/bd893182d98186c17ac4bf8c3a61efa93f3ee739)), closes [#45](https://github.com/bshk-app/ContainerStack/issues/45)
* **cli:** use the app-owned socket by default ([d15cadf](https://github.com/bshk-app/ContainerStack/commit/d15cadf79eb39090241c4643ec422294a9235a7e))
* **compose:** give down and restart a deadline, and recover on it ([3538585](https://github.com/bshk-app/ContainerStack/commit/3538585283d237345a65ff4c4832a81478d4cd60)), closes [#101](https://github.com/bshk-app/ContainerStack/issues/101)
* **compose:** give stack down and restart a deadline, and recover on it ([ba261a9](https://github.com/bshk-app/ContainerStack/commit/ba261a963652bdea2bfbb09052887de842ee0ede))
* **compose:** give the validation temp file a unique name ([40f6f2e](https://github.com/bshk-app/ContainerStack/commit/40f6f2e3071bb62bb97829c6f76cb95daed3573d))
* **compose:** give the validation temp file a unique name ([2fa9a29](https://github.com/bshk-app/ContainerStack/commit/2fa9a29faaacf94cea7ad6bd8b1d9211d8bad80c)), closes [#63](https://github.com/bshk-app/ContainerStack/issues/63)
* **compose:** keep the validation temp name within the filename limit ([6b31c68](https://github.com/bshk-app/ContainerStack/commit/6b31c6820fcedeb316271a7ceb099e04987b99bb))
* **compose:** keep unbounded verbs on their old path, isolate the process registry ([ac630e9](https://github.com/bshk-app/ContainerStack/commit/ac630e970d80868022390bab0c2947c55679f2de))
* **compose:** reject adding a volume onto an occupied target with a different source ([0112423](https://github.com/bshk-app/ContainerStack/commit/01124233744fbf57391e1d8fa09bea29c2580c1c))
* **compose:** reject adding a volume onto an occupied target with a different source ([7f5cf1c](https://github.com/bshk-app/ContainerStack/commit/7f5cf1c81c80f9add7286b5f46486cf7173894c0))
* **containers:** track which container is busy, not that one is ([f0eae41](https://github.com/bshk-app/ContainerStack/commit/f0eae4145291ab7625ba6750b848b50f982a1511))
* **context:** refresh the active installed context ([23c4cfc](https://github.com/bshk-app/ContainerStack/commit/23c4cfcb3ee6fc2117961319d5bd39b0099a58da))
* **core:** a probe that could not run is amber, not a healthy app root ([1f09424](https://github.com/bshk-app/ContainerStack/commit/1f094242dcad514005c63ab2b51b742cf7f62255))
* **core:** drop an untrue invariant and make ProbeResult Equatable ([5e7fce7](https://github.com/bshk-app/ContainerStack/commit/5e7fce74eb8530de94008ec9fa8e8976d8de641a))
* **core:** keep a child's output when the drain starts late ([d6cc86c](https://github.com/bshk-app/ContainerStack/commit/d6cc86c53fc5eb05c9fdd85c2612fd7dc7fc68aa))
* **core:** start a bounded child and register it as one step ([#102](https://github.com/bshk-app/ContainerStack/issues/102)) ([79c5f0f](https://github.com/bshk-app/ContainerStack/commit/79c5f0fb0e8bc9bfd804c31885b0f973d7d373b3))
* **core:** stop the doctor renderer dropping and reordering CLI lines (F-003, T-016a) ([0c9fea0](https://github.com/bshk-app/ContainerStack/commit/0c9fea03d0de0b02990bc4e65f1da4debbcc9231))
* **core:** the Doctor launches nothing, so helperRunning is false ([0097c75](https://github.com/bshk-app/ContainerStack/commit/0097c75ca223695c0201f13ba466c9bf91d8a8f6))
* **core:** treat an empty subnet as uncheckable, not unroutable ([4c8f91e](https://github.com/bshk-app/ContainerStack/commit/4c8f91e7a88b0ad80cdc6c443f19f242a643795f))
* **cstack:** stop claiming a restart that did not happen ([5c8608c](https://github.com/bshk-app/ContainerStack/commit/5c8608c90e1a1bfed34c2e44d8dde3d17da2ad2a))
* **cstack:** stop claiming a restart that did not happen ([c921f36](https://github.com/bshk-app/ContainerStack/commit/c921f36e8ac64da52c3784152ad0aefb399f54b8))
* **doctor:** clear repair failure after healthy diagnostics ([47b877f](https://github.com/bshk-app/ContainerStack/commit/47b877f328c9ff2066502e616d8af58e60b8cc77))
* **hooks:** close five holes cross-model review found in the comment gate ([a265ead](https://github.com/bshk-app/ContainerStack/commit/a265eade3d181b94f94416d18212219205d0d884))
* **hooks:** count comment growth per block, not per run of added lines ([c5b130a](https://github.com/bshk-app/ContainerStack/commit/c5b130aa6a3d8e64532f6dc6c35cec1e121fb0ed))
* **hooks:** honour stop_hook_active so the Stop gate cannot loop ([557566d](https://github.com/bshk-app/ContainerStack/commit/557566df9c0aca03dd9fbfb3a8363af8888def2e))
* **hooks:** lower the comment gate's candidate bound to any length, warn-only ([b72af14](https://github.com/bshk-app/ContainerStack/commit/b72af144a1e959877771f821577ac8b1cf5d3bca))
* **hooks:** lower the comment gate's candidate bound to any length, warn-only ([d5b87d3](https://github.com/bshk-app/ContainerStack/commit/d5b87d3a8b35d6932ff2ca98e953ad1cdc9d8296))
* **hooks:** make the Claude Stop hook informational too, unsign the scratch commit ([3b133d7](https://github.com/bshk-app/ContainerStack/commit/3b133d7dd769dcb8a77245a9dd94cee735e14cd1))
* **hooks:** make the gate path-safe and stop it from looping on a bad payload ([574f36e](https://github.com/bshk-app/ContainerStack/commit/574f36e7737b866e36a2de607501fbb36b77439a))
* **http:** bound failed run cleanup ([8084343](https://github.com/bshk-app/ContainerStack/commit/808434364caa8c1e8dfec39ef073501f85828708))
* **http:** distinguish EINTR from a real connect timeout ([117b0d9](https://github.com/bshk-app/ContainerStack/commit/117b0d9317621b3875ce8a6a652d905a6d13a49b))
* **http:** distinguish EINTR from a real connect timeout ([126af85](https://github.com/bshk-app/ContainerStack/commit/126af8592482cfc5c12983202d6df8d7bb6d8184))
* **http:** give run() the same VM lifecycle timeout as start and delete ([15c4a23](https://github.com/bshk-app/ContainerStack/commit/15c4a2301614bab6e3734c13e54330e210641c44))
* **http:** give run() the same VM lifecycle timeout as start and delete ([7f7e29c](https://github.com/bshk-app/ContainerStack/commit/7f7e29c94e776fb22bc0ff9695702b0eaa0c0565))
* **http:** reject malformed chunk sizes instead of trapping ([9ebc39e](https://github.com/bshk-app/ContainerStack/commit/9ebc39e67a2a95d7f9b48f29b9d3555ccfb1789b))
* **http:** reject malformed chunk sizes instead of trapping ([42396c5](https://github.com/bshk-app/ContainerStack/commit/42396c56b4b00a15b92668f5e8bc50e95f66a0d1))
* **http:** stop treating EINTR as free to retry on the tick-bounded ping path ([ca1cd7f](https://github.com/bshk-app/ContainerStack/commit/ca1cd7f31fba1c5fa1ac104094f076f5971ba9a8))
* **images:** read Arch and OS from image inspect ([fb7f84d](https://github.com/bshk-app/ContainerStack/commit/fb7f84d4b132b938063bf1401581548808206248))
* **images:** read Arch and OS from image inspect ([cbb283d](https://github.com/bshk-app/ContainerStack/commit/cbb283df2d4846da922b6984f7294e0e922ecb5a))
* **images:** show unknown instead of 1970 when Created is absent ([2b7540b](https://github.com/bshk-app/ContainerStack/commit/2b7540bea3f8b7228393fd23085a64929e034327))
* **images:** show unknown instead of 1970 when Created is absent ([3bb6f86](https://github.com/bshk-app/ContainerStack/commit/3bb6f86863335ff3a7ea0ab45783cb00a5380449))
* **memory:** report configured limits without overstating RSS ([038ec29](https://github.com/bshk-app/ContainerStack/commit/038ec29482a133332f4ea795d9b8b16e0cc0f327))
* **process:** bound drains held open by descendants ([808da22](https://github.com/bshk-app/ContainerStack/commit/808da225e28b934414aab4781c7f545d1adb3c02))
* release 0.8.1 with runtime restart and Doctor recovery fixes ([5b88610](https://github.com/bshk-app/ContainerStack/commit/5b88610d36f01af202268a12d529b7234635a494))
* **release:** build the DMG before publishing the release ([8009109](https://github.com/bshk-app/ContainerStack/commit/80091093d13c0d3c6aa8d235886b19afd6f339d8))
* **release:** build the DMG before publishing the release ([a8d3414](https://github.com/bshk-app/ContainerStack/commit/a8d341469c1ee0841b77bbe5892d555546ba64af))
* **release:** put the release notes back in the update panel ([50abe1b](https://github.com/bshk-app/ContainerStack/commit/50abe1b9c14dd90d117fbe8276b6fcb018136f05))
* **release:** stop a false preflight from blocking every CI release ([4d82ebb](https://github.com/bshk-app/ContainerStack/commit/4d82ebb6ea6c26a2ef23735edf913f6650774bcc))
* **release:** two silent failures on the repair and beta paths ([53dcccf](https://github.com/bshk-app/ContainerStack/commit/53dcccf0249e2a91d25af331909cfe7266b3ec56))
* **runtime:** ask the containers to exit before stopping the service ([0b55d3a](https://github.com/bshk-app/ContainerStack/commit/0b55d3ab914758e18c70e14342fc160a0dfbc10b))
* **runtime:** ask the containers to exit before stopping the service ([8bd9910](https://github.com/bshk-app/ContainerStack/commit/8bd9910526b9edca8ade440162767a1d9af19541)), closes [#55](https://github.com/bshk-app/ContainerStack/issues/55)
* **runtime:** bound the graceful stop and recover a lost XPC connection ([db3a623](https://github.com/bshk-app/ContainerStack/commit/db3a6231f6e51c883b1f6ed7aeecf66e03181527))
* **runtime:** claim startup housekeeping ownership ([d8a3cb3](https://github.com/bshk-app/ContainerStack/commit/d8a3cb3643f33d44cca1927cd9ea67e4ba0cb03d))
* **runtime:** end the helper's bounded children on SIGTERM ([#102](https://github.com/bshk-app/ContainerStack/issues/102)) ([b266428](https://github.com/bshk-app/ContainerStack/commit/b2664288885c2577cf6c32206e02c9ea94115084))
* **runtime:** fail the candidate when dup2 does not redirect ([615f6f3](https://github.com/bshk-app/ContainerStack/commit/615f6f32f654f957bd27888e5c1a6b29ddd3822f))
* **runtime:** give every subprocess wait a deadline ([39e4f77](https://github.com/bshk-app/ContainerStack/commit/39e4f77a1485e52606ff8a86e424a89919db0f7c))
* **runtime:** give every subprocess wait a deadline ([89049a5](https://github.com/bshk-app/ContainerStack/commit/89049a557970eb6ec0e7e912c5c7c70c4df350c3))
* **runtime:** give runtime resolution a single owner ([00a3461](https://github.com/bshk-app/ContainerStack/commit/00a3461d0e21fc63fe8d21275dda6afd1f80892e))
* **runtime:** give runtime resolution a single owner ([6c27764](https://github.com/bshk-app/ContainerStack/commit/6c277642b2951201fda924b1c7d91ae3a743d7dd))
* **runtime:** keep saying it while another bridge holds the socket ([ede9a6e](https://github.com/bshk-app/ContainerStack/commit/ede9a6eba9bb4c185ce5bacdc7271e7f97e732b3))
* **runtime:** refuse to adopt a Docker bridge this build does not own ([db0a123](https://github.com/bshk-app/ContainerStack/commit/db0a123b004dd16cc115735049da94f44d5cb47c))
* **runtime:** repair a dead docker context record without activating it ([737807f](https://github.com/bshk-app/ContainerStack/commit/737807f192c9f355c0d90362063e059d9761779e))
* **runtime:** repair a dead docker context record without activating it ([36659bf](https://github.com/bshk-app/ContainerStack/commit/36659bfe31b7967cad4e77b6bcb468e69bd72ccf))
* **runtime:** replace the mutation-slot poll with a continuation queue ([c8186ba](https://github.com/bshk-app/ContainerStack/commit/c8186bae3dca7ae0d134a962359f055bd3cbe14b))
* **runtime:** retire the legacy bundled bridge safely ([27a7122](https://github.com/bshk-app/ContainerStack/commit/27a712266277899dbc2143f0791aee1f394dd7c9))
* **runtime:** stop adopting foreign bridges, freezing the container list and orphaning children ([a06e73c](https://github.com/bshk-app/ContainerStack/commit/a06e73c48e5054beb559c4b7ddd70747f5c9ea53))
* **runtime:** stop offering actions that hang against a foreign bridge ([f08af4b](https://github.com/bshk-app/ContainerStack/commit/f08af4b9d8ba38ee469d244920fc3d56e5790828))
* **runtime:** stop the bridge from filling runtime.log with request lines ([5356691](https://github.com/bshk-app/ContainerStack/commit/5356691ebc904b7139e3bc5b905e7e55c40a497d))
* **runtime:** stop the bridge from filling runtime.log with request lines ([ea7fcae](https://github.com/bshk-app/ContainerStack/commit/ea7fcae9246c05511015274837eef366cafd527b))
* **runtime:** stop the helper running blind when its log cannot be opened ([5690ea8](https://github.com/bshk-app/ContainerStack/commit/5690ea8d5d8055dc4b884f1f03877233ffef06e9))
* **runtime:** stop the helper running blind when its log cannot be opened ([108a922](https://github.com/bshk-app/ContainerStack/commit/108a922516736812546b4457652220d616e62124)), closes [#10](https://github.com/bshk-app/ContainerStack/issues/10)
* **runtime:** take bounded children down with the process that waits on them ([9c2f283](https://github.com/bshk-app/ContainerStack/commit/9c2f283a7464a95f5a7aec4b505f169f3a0ad481))
* **runtime:** use the app-owned socket ([ea804f1](https://github.com/bshk-app/ContainerStack/commit/ea804f16c6c470484e87810063093816cbf63522))
* **runtime:** wait for bridge exit before restarting ([69b9e37](https://github.com/bshk-app/ContainerStack/commit/69b9e37d33377c616589b96d565ef8a8c27ab956))
* **scripts:** restore the app-owned runtime socket ([c776012](https://github.com/bshk-app/ContainerStack/commit/c776012c56a2581383c82f95c0646cc798e82aac))
* **tests:** make service-message expiry deterministic ([deb1f14](https://github.com/bshk-app/ContainerStack/commit/deb1f148a86fe5d1036bebc93dc1ebf4c8d47d35))
* **tests:** make service-message expiry deterministic ([1f82a0e](https://github.com/bshk-app/ContainerStack/commit/1f82a0eddbc4d93db4b3e8ebc2392e1eb595a7af))
* **ui:** confirm single-item deletes before destroying ([5ce79d4](https://github.com/bshk-app/ContainerStack/commit/5ce79d435cf15c628a12fe805fadc1b9b718315e))
* **ui:** confirm single-item deletes before destroying ([d044dd0](https://github.com/bshk-app/ContainerStack/commit/d044dd045dd3eafabc871a1fc9ec7a97a6d2d507))


### Changed

* **app:** build the container screen from the shared list parts ([c2b1bc2](https://github.com/bshk-app/ContainerStack/commit/c2b1bc253a3e1a39f7cb178ddcbc76ace37cb804))
* **app:** give the cached advisories their own type ([f7303fa](https://github.com/bshk-app/ContainerStack/commit/f7303fafd99d7c820d98cbfe3df211dfb40c10c3))
* **app:** give the cached advisories their own type ([874796a](https://github.com/bshk-app/ContainerStack/commit/874796abb8d989acee919b404b93b393570b3e9e))
* **app:** move two runtime helpers out to clear the file_length cap ([3980ffc](https://github.com/bshk-app/ContainerStack/commit/3980ffcb3cb37408fa38c0c80bb5d84843b36544))
* **app:** put what runtime operations wait on behind one seam ([#102](https://github.com/bshk-app/ContainerStack/issues/102)) ([3e0505c](https://github.com/bshk-app/ContainerStack/commit/3e0505c35f71205917c274f75f5fb301f74f9c1d))
* **app:** read each Lucide icon from disk once ([6a560ec](https://github.com/bshk-app/ContainerStack/commit/6a560ec80fd08e8b0fa9f2594389183823d926c6))
* **hooks:** let SwiftLint detect comment blocks, keep only the diff filter ([3b2941e](https://github.com/bshk-app/ContainerStack/commit/3b2941e8721e2fd947b872af60a792589c4d6e66))
* **hooks:** name the warn switch after the check it belongs to ([e63dfab](https://github.com/bshk-app/ContainerStack/commit/e63dfabedc33f8363ae421de58094267c480f2dc))
* **runtime:** remove the bypass around resolution ownership ([f965f38](https://github.com/bshk-app/ContainerStack/commit/f965f38040b738b035848c436694984274be42d9))
* **runtime:** stop spawning the container CLI on every monitor tick ([8c6377d](https://github.com/bshk-app/ContainerStack/commit/8c6377d2d8966cdadaf6a3acdb07afba37eae105))
* **runtime:** stop spawning the container CLI on every monitor tick ([90c4c71](https://github.com/bshk-app/ContainerStack/commit/90c4c71857c7cd2064b71fc75f9392864cb601ca))

## [0.8.1](https://github.com/bshk-app/ContainerStack/compare/v0.8.0...v0.8.1) (2026-10-28)

Runtime restarts now wait for the previous Docker bridge to exit before continuing.
Doctor shows which restart step is running and clears an old repair warning after a
fresh report confirms that every check passed.

### Fixed

- Stop and Restart wait for the Docker bridge to exit. If it ignores the stop signal,
  ContainerStack ends it after a short grace period. A failed stop is reported instead
  of being treated as successful. The app and `cstack` use the same behavior.
- Doctor shows the current restart step and the runtime's error message when available.
- A fully healthy Doctor report clears a warning from an earlier failed repair, including
  after the runtime was restored outside the app. Incomplete checks and timeouts keep the
  warning visible.

## [0.8.0](https://github.com/bshk-app/ContainerStack/compare/v0.7.0...v0.8.0) (2026-10-26)

ContainerStack now uses native macOS lists and a separate inspector column. You can move
through the lists with the keyboard. The runtime now runs Start, Stop and Restart one at a
time, in the order of your clicks.

### Added

- Native lists for the sidebar, Containers, Images, Volumes, Networks and Stacks, with the
  system selection color and VoiceOver support. A click on a row gives that list keyboard
  focus, and the arrow keys move the selection.
- The inspector is a column of its own, with a Hide Inspector button in the toolbar. The
  toolbar buttons of a screen stay over its list.
- Run… in the toolbar opens the Run Container sheet with a picker of local images. Pull
  stays in Images.
- Edit in the context menu of a stack row opens the stack editor, also when the inspector
  is hidden.

### Fixed

- Start, Stop and Restart of the runtime run through one queue. The app does the last action
  that you click. A Stop during a Restart now ends the restart. Before, the app lost that Stop.
- When the app stops the runtime helper, the helper also stops the `container system start`
  that it began. Before, that start could overlap the next Stop.
- Stop and Restart of a stack now have a 120-second deadline. Before, a runtime that did not
  answer kept the stack busy and disabled every stack action.
- A status check on a busy Mac no longer loses the output of the command.
- In light mode, the inspector buttons and the status pills are readable.
- Start in the stack inspector is the prominent button only while a service is stopped.
- Image avatars take their initials from the repository name, not from `docker.io`. A
  container keeps its avatar color across launches.
- The port column shows the first mapping and a count, for example `8080→80 +1`.
- A click anywhere on a group header expands or collapses the group.
- Return in the New Stack sheet creates the stack.
- Logs open at the newest line. A recent container in Overview opens in Containers.
- The sidebar says Overview, and the first inspector tab is Info. The menu bar Quit item has
  Command-Q. The volume inspector no longer shows a Used by row that always read "—".

### Known limitations

- Images and volumes that you create outside the app show only after Refresh or a relaunch.
- Stop on a stack runs `docker compose down`. It removes the containers and the network of
  the stack. A stack that the app found only from container labels then leaves the list.
- A second pull of an image whose layers are already on disk can stay at "Pulling…".
- The inspector has a fixed width of 404 pt. The search field stays over the inspector.

## [0.7.0](https://github.com/bshk-app/ContainerStack/compare/v0.6.1...v0.7.0) (2026-10-06)

ContainerStack gets a Doctor: the checks `cstack doctor` runs, now in the sidebar, with a button
for each problem the app can fix itself. Around it, a round of fixes to how the app starts, stops
and watches the runtime.

### Added

- **Doctor** in the sidebar. It runs when you open it, at most once every 30 seconds, and again
  whenever you ask. Each check shows its verdict, and one with a known fix gets a button: Restart
  Runtime or Repair Docker Context. The window and `cstack doctor` share one report, so they
  cannot disagree; the CLI's text, flags and exit codes are unchanged.
- A stopped runtime shows which checks were skipped and why, instead of nothing or a false pass.
- When another ContainerStack copy's bridge holds the Docker socket — `/Applications` beside a
  development build, say — Doctor names its path and process, and Restart Runtime replaces it.
  A bridge from any other program is named, never stopped.

### Fixed

- The menu bar keeps tracking the runtime after you close the window. Closing it used to stop
  the 3-second monitor, which froze the status and turned off automatic recovery for as long as
  the app lived in the menu bar alone.
- Stop stays stopped. A start still under way no longer launches the runtime after you stop it,
  and nothing begun before or during the Stop — a status check, a container stop that fails
  afterwards — restarts it once the Stop is done. A deliberate stop is no longer reported as
  "Runtime helper exited".
- Start works after a start got stuck. It used to do nothing, without a word, while the helper
  the app had given up on was still running; Start and Restart now end that helper and launch a
  fresh one.
- Stopping a group of containers or taking a stack down hands a lost runtime connection to
  automatic recovery, as stopping a single container already did. "Checking the runtime…" no
  longer stays on screen once the check is over, and a message on one screen no longer replaces
  another screen's.
- A runtime that has just recovered no longer goes blank because a check started before the
  recovery came back late.
- Uninstalling with Homebrew boots out the runtime LaunchAgent, which otherwise kept relaunching
  a helper that was no longer there.
- Adding a volume onto a container path that already has one from a different source is refused,
  instead of reporting success and changing nothing.

### Known limitations

- Published ports still need a runtime restart if a bridge-created network's vmnet helper dies;
  restarting only the containers does not repair the host route. Doctor now spots it and offers
  the restart.
- Running an image from the Images screen still waits for the container to exit before it
  returns.
- A Stop clicked while a restart is in progress, including one the app started on its own, is
  lost.

## [0.6.1](https://github.com/bshk-app/ContainerStack/compare/v0.6.0...v0.6.1) (2026-09-06)


### Fixed

* **runtime:** repair a dead docker context record without activating it ([737807f](https://github.com/bshk-app/ContainerStack/commit/737807f192c9f355c0d90362063e059d9761779e))
* **runtime:** repair a dead docker context record without activating it ([36659bf](https://github.com/bshk-app/ContainerStack/commit/36659bfe31b7967cad4e77b6bcb468e69bd72ccf))
* **runtime:** replace the mutation-slot poll with a continuation queue ([c8186ba](https://github.com/bshk-app/ContainerStack/commit/c8186bae3dca7ae0d134a962359f055bd3cbe14b))

## [0.6.0](https://github.com/bshk-app/ContainerStack/compare/v0.5.1...v0.6.0) (2026-09-03)

Apple Container moves to 1.3.1, which closes six security advisories in the layer
that pulls and unpacks images. Updating the app updates the runtime with it:
`brew upgrade --cask containerstack` pulls both.

### Security

- The pinned runtime moves from Apple Container 1.2.2 to 1.3.1. All six advisories
  fixed in containerization 0.42.0 covered the 0.40.1 that 1.2.2 carried. Four are
  reached by pulling an image from a registry you do not control; one of those,
  CVE-2026-65388, could hand your registry credentials to whatever host the
  registry names in its authentication challenge — over plain HTTP if it asks, and
  on a login that fails, because the client sends them before it stores them.
  The other two are reached by creating a container and by loading an image layout.
- The Docker bridge was ported to that runtime. A tarball whose index carries one
  entry the runtime now refuses to read still loads the images beside it, rather
  than failing whole.

### Added

- A runtime this build was not tested against is now stated plainly, naming the
  version found, the version required, and the command that fixes it. Until now the
  helper exited, launchd restarted it every ten seconds, and the app could only say
  the helper had exited — the same sentence it shows when a socket never opens.

### Changed

- Image pushes and registry inspection now always use `https`. Apple Container 1.3.0
  removed the scheme detection that downgraded internal hosts to plain HTTP, and
  Docker's own default is the same. A registry served over plain HTTP is no longer
  reachable through those two paths.

### Known limitations

Published ports still require a runtime restart if a bridge-created network's vmnet
helper dies; restarting only the containers does not repair the host route. Running
an image from the Images screen still waits for the container to exit before it
returns.

## [0.5.1](https://github.com/bshk-app/ContainerStack/compare/v0.5.0...v0.5.1) (2026-08-30)

A maintenance release about one thing: the app telling the truth about the runtime.
A single dropped connection no longer blanks every list, a runtime that died no longer
leaves its containers on screen, and `cstack doctor` stops calling a network unroutable
when it simply could not be checked.

### Fixed

- One unanswered probe no longer empties the app. The 3-second monitor needs two
  consecutive silences before it calls a healthy runtime offline, and the ping it asks
  now retries a dropped connection the way every other read already did. Declaring the
  runtime dead clears containers, images, volumes and networks and throws away a refresh
  in flight, so being wrong once was expensive. Stop still shows its effect immediately:
  silence with a known cause does not wait for a second opinion.
- The dashboard no longer keeps showing a dead runtime's containers. A runtime that
  fails clears the inventory it described, an explicit failure outranks a lingering
  "Starting", and a refresh still in flight when the runtime was declared dead can no
  longer resurrect what it published.
- `cstack doctor` tells "nothing publishes a port" apart from "nothing could be
  checked". A missing routing table, or a network whose subnet is empty, is reported as
  uncheckable rather than NO ROUTE, and only the networks a published port actually
  depends on are judged.
- Stopping the runtime asks the containers to exit before the service goes down.
- Images Run and `cstack run` no longer give up after five seconds while a micro-VM
  boots: starting and cleaning up a container get the same 120-second window as every
  other VM operation. Run still waits for the container to exit before returning.
- The runtime helper no longer runs blind. When it cannot open
  `~/Library/Logs/ContainerStack/runtime.log` it falls back to a temporary file and
  records why the first destination failed, instead of returning silently — which left
  a crash-looping helper indistinguishable from one that never started.
- Editing a Compose file validates through a uniquely named temporary file, so two
  saves of the same stack can no longer collide next to your compose file.
- An icon that fails to load is now visibly wrong rather than invisible: release builds
  draw a placeholder where a missing asset used to render as a control with no icon.

### Known limitations

Published ports still require a runtime restart if a bridge-created network's vmnet
helper dies; restarting only the containers does not repair the host route.

### Internal

Style gates — swift-format, SwiftLint and the comment-length hook — and the CI wiring
that runs them on every pull request. No user-visible change.

## [0.5.0](https://github.com/bshk-app/ContainerStack/compare/v0.4.2...v0.5.0) (2026-08-27)

Containers can be sized now, and a stop that loses the runtime's XPC service no
longer hangs the app with no way out.

### Added

- Global CPU and memory defaults in Settings, clamped to this Mac's capacity,
  and per-container overrides in the image Run dialog. Apple Container gives
  every container its own VM, and until now each one got the runtime's built-in
  4 CPUs and 1 GiB. The values travel as Docker's `HostConfig.Memory` and
  `HostConfig.NanoCpus`. Fractional CPUs are deliberately not offered: the
  bridge floors them to whole vCPUs, so 0.5 would silently become 1. `cstack`
  keeps its previous behaviour and passes no limits.

### Fixed

- Stopping a container no longer hangs on "Stopping…" indefinitely. Measured
  cause: Apple Container's API server had lost its XPC service, so both stop and
  kill answered HTTP 500 "XPC connection error: Connection interrupted" and
  every later ping answered "Connection invalid", while the app waited out the
  full lifecycle timeout. Stop now pins the daemon's grace window at five
  seconds, bounds its own wait, and treats 304 and 404 as the requested end
  state rather than a failure.
- A lost connection is repaired once instead of repeatedly. The health monitor
  is the only owner of restarts and first proves the API server is really gone
  with `container system status`, so a single transient ping timeout can no
  longer cycle a stack that is serving traffic. A recovery that fails ends the
  startup window, so the manual restart stays available instead of the sidebar
  sitting in a starting state with nothing to click.

### Known limitations

Published ports still require a runtime restart if a bridge-created network's
vmnet helper dies; restarting only the containers does not repair the host route.
The per-container micro-VM architecture also remains slower than OrbStack on the
measured M1 system (4.6x container round trip, 3.6x bind-mount writes).

## [0.4.2](https://github.com/bshk-app/ContainerStack/compare/v0.4.1...v0.4.2) (2026-08-26)

ContainerStack now owns a Docker socket separate from a standalone Socktainer
installation. Upgrading moves the app and its Docker context without stopping or
removing a bridge you run yourself.

### Changed

- The app, `cstack`, Docker context, and verification tools now use
  `~/.containerstack/docker.sock` instead of `~/.socktainer/container.sock`.
  An active `containerstack` Docker context is refreshed during the upgrade. If
  you set `DOCKER_HOST` yourself, update it to the new path.
- The bundled bridge explicitly owns startup housekeeping for the shared Apple
  Container runtime. Homebrew cleanup removes only ContainerStack's state and
  no longer treats `~/.socktainer` as app-owned data.

### Fixed

- Upgrading retires the old bundled bridge before starting its replacement. The
  migration matches both the exact helper path inside ContainerStack.app and the
  old argument list, waits for that process to exit, and aborts safely if it
  cannot confirm retirement. A standalone Socktainer process is left running.

### Known limitations

Published ports still require a runtime restart if a bridge-created network's
vmnet helper dies; restarting only the containers does not repair the host route.
The per-container micro-VM architecture also remains slower than OrbStack on the
measured M1 system (4.6x container round trip, 3.6x bind-mount writes).

## [0.4.1](https://github.com/bshk-app/ContainerStack/compare/v0.4.0...v0.4.1) (2026-08-25)

Starting and stopping containers works again on a machine where another Docker
bridge got there first, and one slow container no longer freezes the rest.

### Fixed

- Another program listening on the Docker socket is now named instead of adopted.
  A bridge from a different build answers every status check while start and stop
  hang - measured past 150 seconds against a container the bundled bridge started
  in 2 - so the app reported a healthy engine while nothing could be controlled.
  It now says which socket is held and what to do, keeps saying it while it is
  true, and stops offering the actions that cannot succeed. Listing containers and
  reading their logs keep working, since that is what you need at that point.
- Acting on one container no longer disables every other one. Stopping can take
  the full two-minute timeout, and for that whole time no other container could be
  started, stopped, deleted or have its logs opened - and a click on a different
  container did nothing at all, without a word.
- Quitting no longer leaves runtime commands running. A command the app was
  waiting on used to survive the app that started it: eight of them were found on
  one machine, the oldest four days old, each wedged and invisible. The Docker
  bridge is unaffected and still outlives the app on purpose.

## [0.4.0](https://github.com/bshk-app/ContainerStack/compare/v0.2.0...v0.4.0) (2026-08-24)

The app can finally update itself. Beyond that: runtime control is harder to
wedge, destructive actions are harder to trigger by accident, and diagnostics
are more honest.

### Added

- In-app updates. Every build since 0.1.0 advertised an update feed and the
  signed feed has been live the whole time, but nothing read it: there was no
  Sparkle, no menu item, and no way to learn a new version existed. "Check for
  Updates…" now sits in the app menu and the menu bar. Checking happens on its
  own; installing waits for you, because replacing the app while containers run
  is not a decision to make on your behalf.
- Docker sections can be hidden from the sidebar through its context menu. Even
  with every Docker item hidden, the same menu remains available to restore them.
- `cstack doctor` reports the configured memory limits of running containers
  against host memory. Unlimited containers and failed inspections are named
  separately instead of being counted as zero.
- Every icon-only action has a descriptive, resource-specific VoiceOver name.

### Fixed

- Releases carry their download again. 0.3.0 was published before its DMG was
  built, and GitHub freezes a release's files the moment it is published, so
  that version shipped empty and could not be repaired. The installer is now
  attached while the release is still a draft, and publishing is the last step.
- Every subprocess wait now has an explicit deadline, except the deliberately
  supervised socktainer process. A child that hangs — or exits while a descendant
  keeps its output pipe open — can no longer wedge monitoring and runtime controls
  forever.
- `cstack runtime restart` continues best-effort recovery after a failed step,
  names each failure, and exits non-zero instead of claiming success.
- GUI, helper, `cstack runtime`, and `cstack doctor` resolve the Apple Container
  binary and its install root through one owner. Environment overrides and the
  vendored runtime no longer apply to only part of the system.
- The bridge no longer writes an INFO request line for every 3-second poll into
  `runtime.log`; warnings, errors, startup and DNS fallback messages remain.
- Deleting a container, image, volume, or network now requires confirmation.
  In-use volumes are not force-deleted.
- Malformed chunked HTTP sizes return a parse error instead of trapping on
  integer overflow or a reversed range.
- Image creation time reports unknown when the runtime returns zero, rather than
  “56 years ago”. Architecture and OS now come from image inspect, the endpoint
  that actually provides them.

### Changed

- The expensive missing-app-root diagnostic runs at most every 30 seconds
  instead of spawning the `container` CLI on every 3-second monitor tick. Manual
  refresh still probes immediately.

### Known limitations

Published ports still require a runtime restart if a bridge-created network's
vmnet helper dies; restarting only the containers does not repair the host route.
The per-container micro-VM architecture also remains slower than OrbStack on the
measured M1 system (4.6x container round trip, 3.6x bind-mount writes).

## 0.3.0

Never released: it was published without its installer and cannot be rebuilt
under that tag. Everything intended for it ships in 0.4.0 above.

## [0.2.0](https://github.com/bshk-app/ContainerStack/compare/v0.1.0...v0.2.0) (2026-08-23)

Updates now come from GitHub. Nothing in the app itself changed: no file under
`Sources/` differs from 0.1.0, and the only edit to the shipped bundle is the
update feed it points at.

### Changed

- Updates are served from a signed feed on GitHub Pages, and the DMG is a GitHub
  Release asset. Both used to come from a server that had to be reachable for an
  update to be found at all; now the artifact lives where the source does.
- The update signing key was rotated as part of the move, so this build trusts a
  different key than 0.1.0 did.

### Known limitations

Unchanged from 0.1.0, and still the two worth knowing before installing:
published ports stop working until the runtime is restarted when a
bridge-created network's vmnet helper dies, and ContainerStack is slower than
OrbStack on an idle M1/16 GiB — container round trip 4.6x, bind mount writes
3.6x, because Apple Container boots one micro-VM per container.

## [Unreleased]

## [0.1.0] - 2026-08-20

First distributed build. Everything below is verified end to end on Apple
Silicon; see `docs/ROADMAP.md` for what is deliberately not here yet.

### Added

- Apple Container 1.2.2 supervised by a bundled runtime helper, with socktainer
  shipped as a sidecar in `Contents/Helpers`.
- A Docker-compatible socket at `~/.socktainer/container.sock`; the app can
  register it as the `containerstack` Docker context when the user opts in.
- `docker` and `docker compose` work unmodified: networks, volumes, published
  ports, `exec`, and `down -v`.
- `cstack`, covering ps, inspect, logs, start/stop/restart/rm, run, images,
  pull, rmi, volumes, networks, df, prune, context, and compose.
- App surfaces for overview, containers grouped by Compose project, images with
  pull/run/delete, volumes, networks, and a runtime panel with polled state.
- A LaunchAgent that keeps the runtime alive without the GUI running.

### Known limitations

- Published ports stop working until the runtime is restarted, when a
  bridge-created network's vmnet helper dies. Restarting the *containers* does
  not help and loses their addresses; the app and `cstack doctor` both say so.
  The root cause sits in Apple's daemon, which owns the re-attach.
- Slower than OrbStack on an idle M1/16 GiB: container round trip 4.6x, bind
  mount writes 3.6x. The gap is architectural — Apple Container boots one
  micro-VM per container.

[Unreleased]: https://github.com/bshk-app/ContainerStack/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bshk-app/ContainerStack/releases/tag/v0.1.0
