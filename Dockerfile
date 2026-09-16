FROM restic/rest-server:0.14.0@sha256:d2aff06f47eb38637dff580c3e6bce4af98f386c396a25d32eb6727ec96214a5 AS runtime-rootfs

ENV S6_KEEP_ENV=1

# s6-overlay is Alpine's packaged process supervisor.  The remaining packages
# support scheduled, locked maintenance and the optional SFTP transport.
RUN apk add --no-cache \
        apache2-utils bash busybox-static curl dcron flock jq openssh restic shadow s6-overlay su-exec tzdata \
    && addgroup -g 1000 restic \
    && adduser -D -H -u 1000 -G restic -s /bin/ash restic \
    && passwd -l restic \
    && mkdir -p /etc/restic-manager/repositories /etc/restic-manager/secrets \
    && chown root:restic /etc/restic-manager /etc/restic-manager/secrets \
    && chmod 0710 /etc/restic-manager /etc/restic-manager/secrets \
    && chmod 0700 /etc/restic-manager/repositories \
    && mkdir -p /srv/restic-sftp/bin /srv/restic-sftp/dev /srv/restic-sftp/lib /srv/restic-sftp/usr/lib/ssh \
    && mknod -m 666 /srv/restic-sftp/dev/null c 1 3 \
    && cp /bin/busybox.static /srv/restic-sftp/bin/busybox \
    && ln -s busybox /srv/restic-sftp/bin/ash \
    && ln -s busybox /srv/restic-sftp/bin/basename \
    && cp /usr/lib/ssh/sftp-server /srv/restic-sftp/usr/lib/ssh/sftp-server \
    && cp /lib/ld-musl-*.so.1 /srv/restic-sftp/lib/ \
    && mkdir -p /srv/restic-sftp/etc \
    && cp /etc/passwd /etc/group /srv/restic-sftp/etc/

COPY entrypoint.sh /usr/local/libexec/restic-setup
COPY restic-callback /usr/local/libexec/restic-callback
COPY moduser.sh /moduser.sh
COPY restic-manager /usr/local/sbin/restic-manager
COPY restic-manager /usr/local/bin/cylo-restic-manager
COPY restic-ssh-command /usr/local/libexec/restic-ssh-command
COPY restic-ssh-command /srv/restic-sftp/bin/restic-ssh-command
COPY rootfs /

RUN chmod 0755 \
        /usr/local/libexec/restic-setup /usr/local/libexec/restic-callback \
        /usr/local/libexec/restic-ssh-command \
        /usr/local/sbin/restic-manager /usr/local/bin/cylo-restic-manager \
        /moduser.sh /srv/restic-sftp/bin/restic-ssh-command \
        /etc/s6-overlay/s6-rc.d/restic-setup/up \
        /etc/s6-overlay/s6-rc.d/rest-server/run \
        /etc/s6-overlay/s6-rc.d/crond/run \
        /etc/s6-overlay/s6-rc.d/sshd/run

# Dockerfile metadata such as VOLUME is inherited and cannot be unset. Export
# the completed filesystem into a clean image config so the parent's obsolete
# anonymous /data volume is not created alongside the Appbox-managed volume.
FROM scratch

COPY --from=runtime-rootfs / /

LABEL org.opencontainers.image.created="2025-05-31T20:27:49Z" \
      org.opencontainers.image.licenses="BSD-2-Clause" \
      org.opencontainers.image.revision="ad130de02124c445300f149fa4f8e826dfdd0e3f" \
      org.opencontainers.image.source="https://github.com/restic/rest-server" \
      org.opencontainers.image.title="rest-server" \
      org.opencontainers.image.version="0.14.0"

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    DATA_DIRECTORY=/srv/restic-sftp/data \
    PASSWORD_FILE=/etc/restic-manager/secrets/rest-htpasswd \
    S6_KEEP_ENV=1

ENTRYPOINT ["/init"]

EXPOSE 8000 2222
