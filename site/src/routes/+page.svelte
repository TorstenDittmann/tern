<script lang="ts">
	import { onMount } from "svelte";

	let hero = $state<HTMLElement>();
	let commands = $state<HTMLElement>();
	let copyLabel = $state("Copy");

	onMount(() => {
		// Reveal on scroll; the agent transcript plays when it comes into view.
		const io = new IntersectionObserver(
			(entries) => {
				for (const e of entries) {
					if (e.isIntersecting) {
						e.target.classList.add("in");
						io.unobserve(e.target);
					}
				}
			},
			{ threshold: 0.15, rootMargin: "0px 0px -6% 0px" },
		);
		document.querySelectorAll(".reveal, .watch").forEach((el) => io.observe(el));

		// The hero window lies back slightly and stands up as you scroll, like a lid opening.
		let queued = false;
		const update = () => {
			queued = false;
			const p = Math.min(1, Math.max(0, scrollY / (innerHeight * 0.55)));
			hero?.style.setProperty("--tilt", (16 * (1 - p)).toFixed(2) + "deg");
			hero?.style.setProperty("--scale", (0.94 + 0.06 * p).toFixed(4));
		};
		const onScroll = () => {
			if (!queued) {
				queued = true;
				requestAnimationFrame(update);
			}
		};
		const animate = !matchMedia("(prefers-reduced-motion: reduce)").matches;
		if (animate) {
			addEventListener("scroll", onScroll, { passive: true });
			update();
		}
		return () => {
			io.disconnect();
			removeEventListener("scroll", onScroll);
		};
	});

	async function copy() {
		const text = commands?.textContent?.replace(/^\$ /gm, "") ?? "";
		try {
			await navigator.clipboard.writeText(text);
			copyLabel = "Copied";
		} catch {
			copyLabel = "Press ⌘C";
		}
		setTimeout(() => (copyLabel = "Copy"), 1600);
	}
</script>

<svelte:head>
	<title>Tern Browser</title>
	<meta name="description" content="Tern is a native Mac browser on WebKit, built for the keyboard, with a CLI and MCP server so coding agents can drive real tabs." />
	<meta property="og:title" content="Tern: a small, fast browser for the Mac" />
	<meta property="og:description" content="Native on WebKit, built for the keyboard, and open to your coding agents." />
	<meta property="og:image" content="https://tern.torsten.work/og.jpg" />
</svelte:head>

<nav class="nav" aria-label="Main">
  <div class="wrap">
    <a class="brand" href="#top">tern</a>
    <a class="hide-s" href="#highlights">Highlights</a>
    <a class="hide-s" href="#agents">Agents</a>
    <a class="hide-s" href="#specs">Specs</a>
    <a href="https://github.com/TorstenDittmann/tern">GitHub</a>
    <a class="pill" href="#get">Get Tern</a>
  </div>
</nav>

<main id="top">
  <section class="hero center">
    <div class="wrap stack">
      <p class="eyebrow">A browser for the Mac</p>
      <h1 class="display">Small app.<br><span class="soft">Big reach.</span></h1>
      <p class="sub">Native on WebKit, built for the keyboard, and open to your coding agents.</p>
      <div class="ctas">
        <a class="pill big" href="#get">Build from source</a>
        <a class="more" href="https://github.com/TorstenDittmann/tern">View on GitHub</a>
      </div>
      <p class="fine">Free and open source. Requires macOS 15.4 or later.</p>
    </div>
    <div class="wrap wide shot">
      <div class="window" bind:this={hero}>
        <enhanced:img src="../lib/assets/hero.png" alt="Tern's new tab page, with the address bar across the top and vertical tabs on the right." sizes="(min-width: 1240px) 1200px, 100vw" fetchpriority="high"></enhanced:img>
      </div>
    </div>
    <div class="wrap">
      <div class="stats">
        <div class="stat"><b>3.8 MB</b><span>release build</span></div>
        <div class="stat"><b>0</b><span>copies of Chromium</span></div>
        <div class="stat"><b>4</b><span>panes in one split</span></div>
        <div class="stat"><b>⌘K</b><span>to everything</span></div>
      </div>
    </div>
  </section>

  <section class="statement center" id="keyboard">
    <div class="wrap stack reveal">
      <h2 class="headline">Your hands stay<br>on the keys.</h2>
      <p class="sub">Search tabs, history and every command from one place. <b>Then press ⌘J and click any link by typing.</b></p>
    </div>
    <div class="wrap wide shot reveal">
      <div class="window"><enhanced:img src="../lib/assets/palette.png" alt="The Tern command palette open, listing recent tabs and commands with their shortcuts." sizes="(min-width: 1240px) 1200px, 100vw" loading="lazy"></enhanced:img></div>
    </div>
    <div class="wrap keys reveal">
      <span><kbd>⌘K</kbd>Command palette</span>
      <span><kbd>⌘P</kbd>Tab picker</span>
      <span><kbd>⌘J</kbd>Link hints</span>
      <span><kbd>⌘E</kbd>Filter tabs</span>
      <span><kbd>⌥⌘→</kbd>Split right</span>
    </div>
  </section>

  <section class="statement center" id="split">
    <div class="wrap stack reveal">
      <h2 class="headline">Your app. Its docs.<br>One window.</h2>
      <p class="sub">Two to four tabs side by side, stacked or in a grid. Drag a tab onto the page, or press ⌥⌘→. <b>Focus follows the pane you click.</b></p>
    </div>
    <div class="wrap wide shot reveal">
      <div class="window"><enhanced:img src="../lib/assets/split.png" alt="Three tabs in a Tern split view grid, grouped together in the tab list." sizes="(min-width: 1240px) 1200px, 100vw" loading="lazy"></enhanced:img></div>
    </div>
  </section>

  <section class="statement" id="highlights">
    <div class="wrap">
      <h2 class="headline center reveal">The small things,<br>all built in.</h2>
      <div class="bento">
        <article class="tile reveal">
          <h3>Link hints</h3>
          <p>Every link, button and field gets a letter code. Type it to click.</p>
          <div class="art hints"><div>Read the <u>docs</u> <span class="chip">DS</span> or the <u>guide</u> <span class="chip">GD</span></div></div>
        </article>
        <article class="tile reveal">
          <h3>Link peek</h3>
          <p>⌥-click opens a floating preview. Keep it as a tab or a split, or press esc.</p>
          <div class="art"><div class="peek"><div class="under"></div><div class="over">peek<br><span style="color:var(--dim)">⌘↩ keep · esc close</span></div></div></div>
        </article>
        <article class="tile reveal">
          <h3>!bangs</h3>
          <p>Search a site directly. About 25 are built in, and you can add your own.</p>
          <div class="art"><div class="box bang"><b>!mdn</b> grid<span class="cursor"></span></div></div>
        </article>
        <article class="tile w3 reveal">
          <h3>Pinned tabs that go back home</h3>
          <p>⌘W on a pinned tab that has wandered off takes it back to its page. Press it again and the tab goes to sleep.</p>
          <div class="art rows">
            <div class="row"><span class="dot"></span>github.com/issues/212<small>wandered off</small></div>
            <div class="row"><span class="dot off"></span>github.com<small>⌘W, back home</small></div>
          </div>
        </article>
        <article class="tile w3 reveal">
          <h3>Compact mode</h3>
          <p>On by default. The address bar stays out of the way until you point at the top edge or press ⌘L.</p>
          <div class="art"><div class="box" style="color:var(--fg-2)">⌘L<span style="color:var(--dim)">&nbsp;&nbsp;the bar comes back over the page</span></div></div>
        </article>
        <article class="tile reveal">
          <h3>Responsive design</h3>
          <p>Phone, tablet and laptop sizes, with the right user agent and pixel density.</p>
          <div class="art devices" aria-hidden="true"><i></i><i></i><i></i></div>
        </article>
        <article class="tile reveal">
          <h3>Requests</h3>
          <p>Every request the page made, filterable, with copy as cURL.</p>
          <div class="art rows">
            <div class="row"><span class="dot"></span>/api/user<small>200 · 41 ms</small></div>
            <div class="row"><span class="dot"></span>/app.js<small>200 · 12 ms</small></div>
            <div class="row" style="color:#E5604F"><span class="dot" style="background:#E5604F"></span>/api/cart<small>500 · 88 ms</small></div>
          </div>
        </article>
        <article class="tile reveal">
          <h3>Extensions</h3>
          <p>Press <b style="font-weight:500;color:var(--fg-2)">Add to Tern</b> in the Chrome Web Store. Safari and unpacked extensions work too.</p>
          <div class="art rows">
            <div class="row"><span class="dot"></span>Chrome Web Store</div>
            <div class="row"><span class="dot"></span>Safari Web Extensions</div>
            <div class="row"><span class="dot"></span>Unpacked, MV2 and MV3</div>
          </div>
        </article>
      </div>
    </div>
  </section>

  <section class="statement" id="agents">
    <div class="wrap center stack reveal">
      <p class="eyebrow">Built for agents</p>
      <h2 class="headline">Your agent gets<br>a real browser.</h2>
      <p class="sub">A local API, a <span class="mono" style="font-size:.9em">tern</span> CLI and an MCP server. Off until you turn it on.</p>
    </div>
    <div class="wrap" style="margin-top:clamp(44px,7vw,72px)">
      <div class="step">
        <div>
          <h3>It sees what you see</h3>
          <p>Claude Code and other MCP clients open tabs, read the page as an outline, click, type, and read the console and network, all in the tabs you already have open.</p>
          <a class="more" href="https://github.com/TorstenDittmann/tern/blob/main/docs/agent-api.md">Agent API</a>
        </div>
        <div class="art watch" aria-label="An agent asks why checkout fails, reads the page and the network log, and reports the cause.">
          <div class="ask">why does checkout fail?</div>
          <div class="call"><i class="dot"></i>tabs_open <span>localhost:3000</span><em>open</em></div>
          <div class="call"><i class="dot"></i>page_click <span>e7</span><em>act</em></div>
          <div class="call"><i class="dot"></i>network_list <span>failedOnly</span><em>read</em></div>
          <div class="call"><i class="dot"></i>console_read <span>error</span><em>read</em></div>
          <div class="reply">POST /api/cart returns 500.<br>The console has the stack trace.</div>
        </div>
      </div>
      <div class="step flip">
        <div>
          <h3>You see what it does</h3>
          <p>A tab an agent is acting on gets a purple ring and a tag, so you always know who's driving. You can also limit agents to the tabs they opened.</p>
        </div>
        <div class="art">
          <div class="driven">
            <span class="tag">Agent is driving</span>
            <div class="field"><i>email</i>ada@example.com<b>page_type e3</b></div>
            <div class="field"><i>plan</i>Team<b>page_select e5</b></div>
          </div>
        </div>
      </div>
      <div class="step">
        <div>
          <h3>One line to connect</h3>
          <p>The API listens only on a Unix socket that only you can open, and no network port is ever opened. Scripts can use the same methods through the CLI.</p>
        </div>
        <div class="term"><span class="p">$</span> claude mcp add tern -- \
    /Applications/Tern.app/Contents/Helpers/tern mcp<br><br><span class="p">$</span> tern page snapshot <span class="c"># outline with refs</span><br><span class="p">$</span> tern page click e7<br><span class="p">$</span> tern console read --level error</div>
      </div>
    </div>
  </section>

  <section class="statement" id="privacy" style="padding-top:clamp(40px,6vw,72px)">
    <div class="wrap center stack reveal">
      <h2 class="headline">Quiet by default.<br>Light by design.</h2>
    </div>
    <div class="wrap" style="margin-top:clamp(44px,7vw,72px)">
      <div class="step flip">
        <div>
          <h3>Blocked before you change a setting</h3>
          <p>EasyList and EasyPrivacy are compiled to native WebKit rules, so blocking costs the page almost nothing. Links lose tracking parameters before they load, and local dev servers are left alone.</p>
        </div>
        <div class="art">
          <div class="url">shop.example.com/item<s>?utm_source=mail&amp;fbclid=x1</s></div>
          <div class="blocks">
            <div>ad network<em>blocked</em></div>
            <div>tracker<em>blocked</em></div>
            <div class="ok">localhost:3000<em>left alone</em></div>
            <div class="ok">*.test<em>left alone</em></div>
          </div>
        </div>
      </div>
      <div class="step">
        <div>
          <h3>Tabs that give memory back</h3>
          <p>A restored tab is just a URL and its history until you open it, so 200 tabs cost about as much as one. Background tabs are suspended after 15 minutes, and sooner when macOS runs low on memory.</p>
        </div>
        <div class="art tabs">
          <div class="tabrow on">localhost:3000<small>running</small></div>
          <div class="tabrow">docs.swift.org<small>suspended ☾</small></div>
          <div class="tabrow">github.com<small>suspended ☾</small></div>
          <div class="tabrow">news.ycombinator.com<small>not loaded yet</small></div>
        </div>
      </div>
    </div>
  </section>

  <section class="statement" id="specs" style="padding-top:clamp(40px,6vw,72px)">
    <div class="wrap">
      <h2 class="headline reveal">Tech specs</h2>
      <div class="specs">
        <div class="spec"><h3>Size</h3><p>3.8 MB, release build. No Electron and no bundled Chromium.</p></div>
        <div class="spec"><h3>Engine</h3><p>WebKit through WKWebView, in plain AppKit and Swift.</p></div>
        <div class="spec"><h3>Requires</h3><p>macOS 15.4 or later. To build, Xcode 16.3 or later and XcodeGen.</p></div>
        <div class="spec"><h3>Extensions</h3><p>Chrome Web Store, Safari Web Extensions, and unpacked MV2 and MV3 extensions.</p></div>
        <div class="spec"><h3>Automation</h3><p>JSON-RPC over a local Unix socket, the <code>tern</code> CLI, and an MCP server.</p></div>
        <div class="spec"><h3>License</h3><p>MIT. Free and open source.</p></div>
      </div>
    </div>
  </section>

  <section class="get center" id="get">
    <div class="wrap stack reveal">
      <h2 class="display" style="font-size:clamp(44px,8vw,88px)">Build it in<br>about a minute.</h2>
      <p class="sub">There are no signed releases yet, so you build Tern from source. You'll need Xcode and XcodeGen.</p>
      <div class="term">
        <button class="copy" type="button" onclick={copy}>{copyLabel}</button>
<pre bind:this={commands}><span class="p">$ </span>brew install xcodegen
<span class="p">$ </span>git clone https://github.com/TorstenDittmann/tern.git
<span class="p">$ </span>cd tern
<span class="p">$ </span>make release</pre>
      </div>
    </div>
  </section>
</main>

<footer>
  <div class="wrap">
    <span>MIT © Torsten Dittmann</span>
    <span class="sp"></span>
    <a href="https://github.com/TorstenDittmann/tern">GitHub</a>
    <a href="https://github.com/TorstenDittmann/tern/issues">Issues</a>
    <a href="https://github.com/TorstenDittmann/tern#documentation">Documentation</a>
  </div>
</footer>
