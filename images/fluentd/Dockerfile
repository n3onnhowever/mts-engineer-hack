ARG FLUENTD_BASE_IMAGE=docker.io/fluent/fluentd:v1.19.3-debian-2.3@sha256:ee423d1c1cb9882037bc6ab3cdf86fcd22da4b11a2f9f21a7b0a5b2041718867
FROM ${FLUENTD_BASE_IMAGE}
USER root
ARG FLUENTD_VERSION=1.19.4
ARG FLUENTD_GEM_SHA256=3efc978bb5552df92ad34f9f486cbfad27df52e80eeedd5657f7260d190b1a74
ARG FLUENTD_LOKI_PLUGIN_VERSION=1.3.0
ARG FLUENTD_LOKI_PLUGIN_GEM_SHA256=a9fb5177bbe391da4fb1de434659125e5d39010b67340953742d68d9fddbf86c
WORKDIR /opt/mts-fluentd
COPY Gemfile Gemfile.lock fetch-gems.rb loki-retry-all.rb ./
# Reuse native gems locked by the digest-pinned base; never resolve or download
# transitive dependencies during the build. Check both downloaded package hashes.
RUN ruby fetch-gems.rb && \
    gem uninstall fluentd --version 1.19.3 --all --executables --ignore-dependencies && \
    gem install --local --no-document --ignore-dependencies /tmp/fluentd.gem /tmp/loki-plugin.gem && \
    bundle check && \
    bundle exec ruby -rfluent/version -r./loki-retry-all -e 'abort "Wrong Fluentd version" unless Fluent::VERSION == "1.19.4"' && \
    rm /tmp/fluentd.gem /tmp/loki-plugin.gem && \
    (getent group 2000 || groupadd --gid 2000 app-logs) && \
    useradd --uid 10002 --gid 2000 --no-create-home --home-dir /fluentd mts-fluentd && \
    mkdir -p /fluentd/state && chown 10002:2000 /fluentd/state
ENV BUNDLE_GEMFILE=/opt/mts-fluentd/Gemfile BUNDLE_FROZEN=true
# Dedicated numeric identity lets kubelet verify runAsNonRoot without relying
# on the upstream image's fluent UID. The pod fsGroup grants emptyDir access.
USER 10002:2000
ENTRYPOINT ["bundle", "exec", "fluentd"]
CMD ["--no-supervisor", "-r", "/opt/mts-fluentd/loki-retry-all.rb", "-c", "/fluentd/etc/fluent.conf"]
