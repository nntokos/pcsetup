ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates git openssh-server python3 python3-pip stow sudo \
    && mkdir -p /run/sshd /srv/git \
    && useradd --create-home --shell /bin/bash machstrap-nosudo \
    && useradd --create-home --shell /bin/bash machstrap-nopass \
    && useradd --create-home --shell /bin/bash machstrap-password \
    && useradd --create-home --shell /bin/bash machstrap-symlink \
    && useradd --create-home --shell /bin/bash machstrap-stow \
    && useradd --create-home --shell /bin/bash machstrap-script \
    && useradd --create-home --shell /bin/bash machstrap-none \
    && useradd --create-home --shell /bin/bash machstrap-vault \
    && useradd --create-home --shell /bin/bash machstrap-tags \
    && printf '%s\n' \
        'Defaults logfile="/var/log/machstrap-sudo.log"' \
        'Defaults loglinelen=0' \
        'machstrap-nopass ALL=(root) NOPASSWD: ALL' \
        'machstrap-password ALL=(root) ALL' \
        >/etc/sudoers.d/machstrap-test \
    && chmod 0440 /etc/sudoers.d/machstrap-test \
    && ssh-keygen -A \
    && git init --bare /srv/git/fixture.git \
    && git init /tmp/fixture-work \
    && git -C /tmp/fixture-work config user.name 'Machstrap Test' \
    && git -C /tmp/fixture-work config user.email test@example.invalid \
    && printf 'fixture\n' >/tmp/fixture-work/README.md \
    && git -C /tmp/fixture-work add README.md \
    && git -C /tmp/fixture-work commit -m fixture \
    && git -C /tmp/fixture-work branch -M main \
    && git -C /tmp/fixture-work remote add origin /srv/git/fixture.git \
    && git -C /tmp/fixture-work push origin main \
    && rm -rf /tmp/fixture-work \
    && git init --bare /srv/git/dotfiles.git \
    && git init /tmp/dotfiles-work \
    && git -C /tmp/dotfiles-work config user.name 'Machstrap Test' \
    && git -C /tmp/dotfiles-work config user.email test@example.invalid \
    && mkdir -p /tmp/dotfiles-work/shell \
    && printf 'stowed\n' >/tmp/dotfiles-work/shell/.stow-test \
    && printf '%s\n' '#!/bin/sh' 'printf "script-installed\\n" >"$HOME/.script-installed"' \
        >/tmp/dotfiles-work/install.sh \
    && chmod 0755 /tmp/dotfiles-work/install.sh \
    && git -C /tmp/dotfiles-work add shell install.sh \
    && git -C /tmp/dotfiles-work commit -m dotfiles \
    && git -C /tmp/dotfiles-work branch -M main \
    && git -C /tmp/dotfiles-work remote add origin /srv/git/dotfiles.git \
    && git -C /tmp/dotfiles-work push origin main \
    && rm -rf /tmp/dotfiles-work \
    && git config --system --add safe.directory /srv/git/fixture.git \
    && git config --system --add safe.directory /srv/git/dotfiles.git \
    && chmod -R a+rX /srv/git

COPY entrypoint.sh /usr/local/sbin/machstrap-test-entrypoint
RUN chmod 0755 /usr/local/sbin/machstrap-test-entrypoint

EXPOSE 22
ENTRYPOINT ["/usr/local/sbin/machstrap-test-entrypoint"]
