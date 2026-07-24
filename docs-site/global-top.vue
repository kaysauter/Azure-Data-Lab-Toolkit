<template>
	<nav class="deck-nav" aria-label="Presentation links">
		<a class="agenda-link" href="#/2">Agenda</a>
		<a class="front-page-link" href="/Azure-Data-Lab-Toolkit/">Back to docs</a>
	</nav>
	<a class="source-footer" href="https://github.com/kaysauter/Azure-Data-Lab-Toolkit">
		github.com/kaysauter/Azure-Data-Lab-Toolkit
	</a>
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
	max-width: min(28rem, calc(100vw - 2.2rem));
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

@media print {
	.deck-nav {
		display: none;
	}
}

@media (max-width: 700px) {
	.source-footer {
		display: none;
	}
}
</style>
