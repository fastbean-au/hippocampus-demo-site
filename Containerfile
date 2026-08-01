# Self-contained landing-page image: Caddy with the static site baked in. It carries no
# host-path or cross-repo dependencies, so it builds and runs anywhere. The showcase's front
# proxy reaches it over the shared network by service name (see compose.yaml).
FROM caddy:2

COPY Caddyfile /etc/caddy/Caddyfile
COPY index.html /srv/site/index.html
COPY robots.txt /srv/site/robots.txt
COPY sitemap.xml /srv/site/sitemap.xml
COPY assets/ /srv/site/assets/

# Stamp the sitemap's <lastmod> with the image build date (UTC) so it reflects the deploy
# rather than a hand-maintained date that drifts. The date in the checked-in sitemap.xml is
# only a fallback for local, no-build previews. Busybox sed + BRE, portable on the Alpine base.
RUN sed -i "s#<lastmod>[0-9-]*</lastmod>#<lastmod>$(date -u +%Y-%m-%d)</lastmod>#" \
	/srv/site/sitemap.xml
