<template>
	<nav class="deck-nav" aria-label="Presentation links">
		<a class="agenda-link" href="#/2">Agenda</a>
		<a class="front-page-link" href="/Azure-Data-Lab-Toolkit/">Back to docs</a>
	</nav>
	<a class="source-footer" href="https://github.com/kaysauter/Azure-Data-Lab-Toolkit">
		github.com/kaysauter/Azure-Data-Lab-Toolkit
	</a>
	<div class="portrait-notice" role="note">
		Rotate for a readable presentation.
		<a href="/Azure-Data-Lab-Toolkit/overview/">Read the docs</a>
	</div>
</template>

<style scoped>
.deck-nav {
	position: fixed;
	top: 1rem;
	right: 1rem;
	z-index: 100;
	display: flex;
	gap: 0.45rem;
}

.agenda-link,
.front-page-link {
	display: inline-flex;
	align-items: center;
	min-height: 2rem;
	border: 1px solid rgba(125, 211, 252, 0.48);
	border-radius: 6px;
	padding: 0.4rem 0.7rem;
	background: rgba(15, 23, 42, 0.78);
	color: #e5edf8;
	font-size: 0.78rem;
	font-weight: 700;
	line-height: 1;
	text-decoration: none;
	backdrop-filter: blur(10px);
}

.agenda-link:hover,
.front-page-link:hover {
	background: rgba(14, 165, 233, 0.9);
	color: #06111f;
}

.source-footer {
	position: fixed;
	bottom: 0.7rem;
	right: 1.1rem;
	z-index: 100;
	border: 1px solid rgba(125, 211, 252, 0.30);
	border-radius: 6px;
	max-width: min(22rem, 34vw);
	overflow: hidden;
	padding: 0.28rem 0.55rem;
	background: rgba(15, 23, 42, 0.72);
	color: rgba(229, 237, 248, 0.84);
	font-size: 0.62rem;
	font-weight: 600;
	line-height: 1;
	text-decoration: none;
	text-overflow: ellipsis;
	white-space: nowrap;
	backdrop-filter: blur(10px);
}

.source-footer:hover {
	background: rgba(14, 165, 233, 0.9);
	color: #06111f;
}

.portrait-notice {
	display: none;
}

@media print {
	.deck-nav,
	.source-footer,
	.portrait-notice {
		display: none;
	}
}

@media (max-width: 760px) {
	.source-footer {
		display: none;
	}

	.deck-nav {
		top: 0.65rem;
		right: 0.65rem;
	}
}

@media (max-width: 760px) and (orientation: portrait) {
	.portrait-notice {
		position: fixed;
		right: 1.5rem;
		bottom: 1.5rem;
		left: 1.5rem;
		z-index: 120;
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 1.25rem;
		border: 3px solid rgba(125, 211, 252, 0.62);
		border-radius: 6px;
		padding: 1rem 1.25rem;
		background: rgba(15, 23, 42, 0.94);
		color: #e5edf8;
		font-size: 2.25rem;
		font-weight: 650;
		line-height: 1.2;
	}

	.portrait-notice a {
		color: #7dd3fc;
		white-space: nowrap;
	}
}
</style>
