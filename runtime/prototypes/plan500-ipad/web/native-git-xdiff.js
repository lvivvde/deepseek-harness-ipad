/*
 * Line counts for `git diff-tree --numstat`, as git's bundled xdiff computes them.
 *
 * Port of the Myers split and the record clean-up of LibXDiff as shipped in git v2.54.0
 * (xdiff/xdiffi.c, xdiff/xprepare.c, xdiff/xutils.c).
 *
 *  LibXDiff by Davide Libenzi ( File Differential Library )
 *  Copyright (C) 2003  Davide Libenzi
 *  JavaScript port for the native read-only Git of deepseek-harness-ipad.
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this library; if not, see
 *  <http://www.gnu.org/licenses/>.
 *
 * Only the default (Myers, non-minimal) algorithm with no whitespace flags is ported:
 * the numstat counts are the changed records on each side, which the hunk compaction
 * that follows in xdiff never alters.
 */
(function (root) {
	"use strict";

	const MAX_COST_MIN = 256;
	const HEUR_MIN_COST = 256;
	const SNAKE_CNT = 20;
	const K_HEUR = 4;
	const KPDIS_RUN = 4;
	const MAX_EQLIMIT = 1024;
	const SIMSCAN_WINDOW = 100;
	const LINE_MAX = Number.MAX_SAFE_INTEGER;
	const DISCARD = 0, KEEP = 1, INVESTIGATE = 2;

	function bogosqrt(n) {
		let i = 1;
		for (; n > 0; n = Math.floor(n / 4)) i *= 2;
		return i;
	}

	/** Records split after each '\n'; the last one may lack it. */
	function records(bytes) {
		const out = [];
		let start = 0;
		for (let i = 0; i < bytes.length; i++) {
			if (bytes[i] === 0x0a) {
				out.push([start, i + 1]);
				start = i + 1;
			}
		}
		if (start < bytes.length) out.push([start, bytes.length]);
		return out;
	}

	function prepare(a, b) {
		const classes = new Map();
		const len1 = [], len2 = [];
		const decoder = (bytes, [s, e]) => {
			let key = "";
			for (let i = s; i < e; i += 8192) key += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(e, i + 8192)));
			return key;
		};
		const side = (bytes, pass) => {
			const recs = records(bytes);
			const hash = new Array(recs.length);
			for (let i = 0; i < recs.length; i++) {
				const key = decoder(bytes, recs[i]);
				let idx = classes.get(key);
				if (idx === undefined) {
					idx = classes.size;
					classes.set(key, idx);
					len1.push(0);
					len2.push(0);
				}
				(pass === 1 ? len1 : len2)[idx]++;
				hash[i] = idx;
			}
			return { nrec: recs.length, hash, changed: new Uint8Array(recs.length + 2), rindex: [], nreff: 0, dstart: 0, dend: recs.length - 1 };
		};
		const x1 = side(a, 1), x2 = side(b, 2);
		trimEnds(x1, x2);
		cleanup(x1, x2, len1, len2);
		return [x1, x2];
	}

	function trimEnds(x1, x2) {
		const lim = Math.min(x1.nrec, x2.nrec);
		let i = 0;
		for (; i < lim; i++) if (x1.hash[i] !== x2.hash[i]) break;
		x1.dstart = x2.dstart = i;
		const rest = lim - i;
		let j = 0;
		for (; j < rest; j++) if (x1.hash[x1.nrec - 1 - j] !== x2.hash[x2.nrec - 1 - j]) break;
		x1.dend = x1.nrec - j - 1;
		x2.dend = x2.nrec - j - 1;
	}

	function cleanMatch(action, i, s, e) {
		if (i - s > SIMSCAN_WINDOW) s = i - SIMSCAN_WINDOW;
		if (e - i > SIMSCAN_WINDOW) e = i + SIMSCAN_WINDOW;
		let r, rdis0 = 0, rpdis0 = 1, rdis1 = 0, rpdis1 = 1;
		for (r = 1; i - r >= s; r++) {
			if (action[i - r] === DISCARD) rdis0++;
			else if (action[i - r] === INVESTIGATE) rpdis0++;
			else break;
		}
		if (rdis0 === 0) return false;
		for (r = 1; i + r <= e; r++) {
			if (action[i + r] === DISCARD) rdis1++;
			else if (action[i + r] === INVESTIGATE) rpdis1++;
			else break;
		}
		if (rdis1 === 0) return false;
		rdis1 += rdis0;
		rpdis1 += rpdis0;
		return rpdis1 * KPDIS_RUN < rpdis1 + rdis1;
	}

	function cleanup(x1, x2, len1, len2) {
		const mark = (x, other) => {
			const action = new Uint8Array(x.nrec + 1);
			const mlim = Math.min(bogosqrt(x.nrec), MAX_EQLIMIT);
			for (let i = x.dstart; i <= x.dend; i++) {
				const nm = other[x.hash[i]];
				action[i] = nm === 0 ? DISCARD : nm >= mlim ? INVESTIGATE : KEEP;
			}
			for (let i = x.dstart; i <= x.dend; i++) {
				if (action[i] === KEEP || (action[i] === INVESTIGATE && !cleanMatch(action, i, x.dstart, x.dend))) {
					x.rindex[x.nreff++] = i;
				} else {
					x.changed[i + 1] = 1;
				}
			}
		};
		mark(x1, len2);
		mark(x2, len1);
	}

	function split(x1, off1, lim1, x2, off2, lim2, kvdf, kvdb, base, needMin, spl, env) {
		const h1 = (i) => x1.hash[x1.rindex[i]];
		const h2 = (i) => x2.hash[x2.rindex[i]];
		const dmin = off1 - lim2, dmax = lim1 - off2;
		const fmid = off1 - off2, bmid = lim1 - lim2;
		const odd = (fmid - bmid) & 1;
		let fmin = fmid, fmax = fmid, bmin = bmid, bmax = bmid;
		let d, i1, i2, prev1, best, dd, v, k;
		const F = (idx) => kvdf[idx + base], B = (idx) => kvdb[idx + base];
		kvdf[fmid + base] = off1;
		kvdb[bmid + base] = lim1;
		for (let ec = 1; ; ec++) {
			let gotSnake = false;
			if (fmin > dmin) kvdf[--fmin - 1 + base] = -1;
			else ++fmin;
			if (fmax < dmax) kvdf[++fmax + 1 + base] = -1;
			else --fmax;
			for (d = fmax; d >= fmin; d -= 2) {
				if (F(d - 1) >= F(d + 1)) i1 = F(d - 1) + 1;
				else i1 = F(d + 1);
				prev1 = i1;
				i2 = i1 - d;
				for (; i1 < lim1 && i2 < lim2 && h1(i1) === h2(i2); i1++, i2++);
				if (i1 - prev1 > env.snakeCnt) gotSnake = true;
				kvdf[d + base] = i1;
				if (odd && bmin <= d && d <= bmax && B(d) <= i1) {
					spl.i1 = i1; spl.i2 = i2; spl.minLo = spl.minHi = true;
					return ec;
				}
			}
			if (bmin > dmin) kvdb[--bmin - 1 + base] = LINE_MAX;
			else ++bmin;
			if (bmax < dmax) kvdb[++bmax + 1 + base] = LINE_MAX;
			else --bmax;
			for (d = bmax; d >= bmin; d -= 2) {
				if (B(d - 1) < B(d + 1)) i1 = B(d - 1);
				else i1 = B(d + 1) - 1;
				prev1 = i1;
				i2 = i1 - d;
				for (; i1 > off1 && i2 > off2 && h1(i1 - 1) === h2(i2 - 1); i1--, i2--);
				if (prev1 - i1 > env.snakeCnt) gotSnake = true;
				kvdb[d + base] = i1;
				if (!odd && fmin <= d && d <= fmax && i1 <= F(d)) {
					spl.i1 = i1; spl.i2 = i2; spl.minLo = spl.minHi = true;
					return ec;
				}
			}
			if (needMin) continue;
			if (gotSnake && ec > env.heurMin) {
				for (best = 0, d = fmax; d >= fmin; d -= 2) {
					dd = d > fmid ? d - fmid : fmid - d;
					i1 = F(d);
					i2 = i1 - d;
					v = (i1 - off1) + (i2 - off2) - dd;
					if (v > K_HEUR * ec && v > best && off1 + env.snakeCnt <= i1 && i1 < lim1 && off2 + env.snakeCnt <= i2 && i2 < lim2) {
						for (k = 1; h1(i1 - k) === h2(i2 - k); k++) {
							if (k === env.snakeCnt) {
								best = v; spl.i1 = i1; spl.i2 = i2;
								break;
							}
						}
					}
				}
				if (best > 0) { spl.minLo = true; spl.minHi = false; return ec; }
				for (best = 0, d = bmax; d >= bmin; d -= 2) {
					dd = d > bmid ? d - bmid : bmid - d;
					i1 = B(d);
					i2 = i1 - d;
					v = (lim1 - i1) + (lim2 - i2) - dd;
					if (v > K_HEUR * ec && v > best && off1 < i1 && i1 <= lim1 - env.snakeCnt && off2 < i2 && i2 <= lim2 - env.snakeCnt) {
						for (k = 0; h1(i1 + k) === h2(i2 + k); k++) {
							if (k === env.snakeCnt - 1) {
								best = v; spl.i1 = i1; spl.i2 = i2;
								break;
							}
						}
					}
				}
				if (best > 0) { spl.minLo = false; spl.minHi = true; return ec; }
			}
			if (ec >= env.mxcost) {
				let fbest = -1, fbest1 = -1;
				for (d = fmax; d >= fmin; d -= 2) {
					i1 = Math.min(F(d), lim1);
					i2 = i1 - d;
					if (lim2 < i2) { i1 = lim2 + d; i2 = lim2; }
					if (fbest < i1 + i2) { fbest = i1 + i2; fbest1 = i1; }
				}
				let bbest = LINE_MAX, bbest1 = LINE_MAX;
				for (d = bmax; d >= bmin; d -= 2) {
					i1 = Math.max(off1, B(d));
					i2 = i1 - d;
					if (i2 < off2) { i1 = off2 + d; i2 = off2; }
					if (i1 + i2 < bbest) { bbest = i1 + i2; bbest1 = i1; }
				}
				if ((lim1 + lim2) - bbest < fbest - (off1 + off2)) {
					spl.i1 = fbest1; spl.i2 = fbest - fbest1; spl.minLo = true; spl.minHi = false;
				} else {
					spl.i1 = bbest1; spl.i2 = bbest - bbest1; spl.minLo = false; spl.minHi = true;
				}
				return ec;
			}
		}
	}

	function compare(x1, x2, kvdf, kvdb, base, env) {
		// The C recursion, with an explicit stack so long files cannot overflow the JS stack.
		const stack = [[0, x1.nreff, 0, x2.nreff, false]];
		while (stack.length > 0) {
			let [off1, lim1, off2, lim2, needMin] = stack.pop();
			while (off1 < lim1 && off2 < lim2 && x1.hash[x1.rindex[off1]] === x2.hash[x2.rindex[off2]]) { off1++; off2++; }
			while (off1 < lim1 && off2 < lim2 && x1.hash[x1.rindex[lim1 - 1]] === x2.hash[x2.rindex[lim2 - 1]]) { lim1--; lim2--; }
			if (off1 === lim1) {
				for (; off2 < lim2; off2++) x2.changed[x2.rindex[off2] + 1] = 1;
			} else if (off2 === lim2) {
				for (; off1 < lim1; off1++) x1.changed[x1.rindex[off1] + 1] = 1;
			} else {
				const spl = { i1: 0, i2: 0, minLo: false, minHi: false };
				split(x1, off1, lim1, x2, off2, lim2, kvdf, kvdb, base, needMin, spl, env);
				stack.push([spl.i1, lim1, spl.i2, lim2, spl.minHi]);
				stack.push([off1, spl.i1, off2, spl.i2, spl.minLo]);
			}
		}
	}

	/**
	 * numstat counts for two blobs that git would diff as text.
	 * @param {Uint8Array} a - old content.
	 * @param {Uint8Array} b - new content.
	 * @returns {{added: number, deleted: number}}
	 */
	function numstat(a, b) {
		const [x1, x2] = prepare(a, b);
		const ndiags = x1.nreff + x2.nreff + 3;
		const kvdf = new Array(ndiags + 2), kvdb = new Array(ndiags + 2);
		const base = x2.nreff + 1;
		const env = { mxcost: Math.max(bogosqrt(ndiags), MAX_COST_MIN), snakeCnt: SNAKE_CNT, heurMin: HEUR_MIN_COST };
		compare(x1, x2, kvdf, kvdb, base, env);
		let deleted = 0, added = 0;
		for (let i = 1; i <= x1.nrec; i++) deleted += x1.changed[i];
		for (let i = 1; i <= x2.nrec; i++) added += x2.changed[i];
		return { added, deleted };
	}

	root.DshNativeGitXdiff = { numstat };
})(globalThis);
