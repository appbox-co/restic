# Third-party components

This repository contains Appbox container packaging and integration code.
It is not the upstream Restic client or REST server project. Its license does
not replace the licenses of third-party software or artwork.

The Docker build uses these upstream projects:

- [rest-server](https://github.com/restic/rest-server), BSD-2-Clause.
  Copyright © 2015, Bertil Chapuis; © 2016, Zlatko Čalušić, Alexander Neumann;
  © 2017, The Rest Server Authors.
  [Upstream license](https://github.com/restic/rest-server/blob/master/LICENSE).
- [restic](https://github.com/restic/restic), BSD-2-Clause.
  Copyright (c) 2014, Alexander Neumann.
  [Upstream license](https://github.com/restic/restic/blob/master/LICENSE).

The container also installs Alpine packages, including OpenSSH, BusyBox,
s6-overlay, curl, jq, and their dependencies, under their respective licenses.
This repository does not vendor those package sources or distribute a built
container image. When distributing a built image, retain the required notices
and meet the source-availability and other obligations of its components.

Product names and logos remain the property of their respective owners.
