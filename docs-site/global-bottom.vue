<template>
	<!--
		Presentation progress. Rendered on every slide except the cover, so the
		title slide stays clean. Uses $slidev.nav, which is Slidev's documented
		public navigation API, rather than importing internals that move between
		versions.

		The counter sits bottom-left because global-top.vue already occupies
		bottom-right with the source link.
	-->
	<div
		v-if="$slidev.nav.currentPage > 1"
		class="deck-progress"
		role="group"
		aria-label="Presentation progress"
	>
		<span class="deck-progress-count">
			{{ $slidev.nav.currentPage }} <i>/</i> {{ $slidev.nav.total }}
		</span>
	</div>
	<div
		v-if="$slidev.nav.currentPage > 1"
		class="deck-progress-track"
		aria-hidden="true"
	>
		<div
			class="deck-progress-fill"
			:style="{ width: fillWidth }"
		/>
	</div>
</template>

<script setup>
import { computed } from 'vue'
import { useSlideContext } from '@slidev/client'

// useSlideContext() is Slidev's public accessor. Do NOT reach for
// inject('$slidev'): the real injection key is '$$slidev-context'
// (@slidev/client/constants.ts), so injecting '$slidev' silently returns
// undefined and the bar would never fill without any error.
const { $slidev } = useSlideContext()

const fillWidth = computed(() => {
	const total = Number($slidev?.nav?.total ?? 0)
	const current = Number($slidev?.nav?.currentPage ?? 0)
	if (!Number.isFinite(total) || total < 1) {
		return '0%'
	}
	const ratio = Math.min(Math.max(current / total, 0), 1)
	return `${(ratio * 100).toFixed(2)}%`
})
</script>

<style scoped>
.deck-progress {
	position: fixed;
	bottom: 0.7rem;
	left: 1.1rem;
	z-index: 100;
	display: flex;
	align-items: center;
	pointer-events: none;
}

.deck-progress-count {
	border: 1px solid rgba(125, 211, 252, 0.3);
	border-radius: 6px;
	padding: 0.28rem 0.55rem;
	background: rgba(38, 50, 55, 0.85);
	color: rgba(229, 237, 248, 0.84);
	font-size: 0.62rem;
	font-weight: 700;
	font-variant-numeric: tabular-nums;
	line-height: 1;
	white-space: nowrap;
	backdrop-filter: blur(10px);
}

.deck-progress-count i {
	margin: 0 0.15rem;
	font-style: normal;
	opacity: 0.55;
}

.deck-progress-track {
	position: fixed;
	right: 0;
	bottom: 0;
	left: 0;
	z-index: 100;
	height: 3px;
	background: rgba(125, 211, 252, 0.14);
	pointer-events: none;
}

.deck-progress-fill {
	height: 100%;
	/* No transition on width: a tween would still be animating while the
	   speaker is already talking to the next slide, and on a projector the
	   partial state reads as a rendering fault rather than an animation. */
	background: #65d3e2;
}

html.light .deck-progress-count {
	border-color: rgba(8, 127, 140, 0.35);
	background: rgba(255, 255, 255, 0.92);
	color: #1f3038;
}

html.light .deck-progress-track {
	background: rgba(8, 127, 140, 0.16);
}

html.light .deck-progress-fill {
	background: #087f8c;
}

@media print {
	.deck-progress,
	.deck-progress-track {
		display: none;
	}
}

@media (max-width: 760px) {
	.deck-progress {
		display: none;
	}
}
</style>
