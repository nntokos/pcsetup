# Profile scripts

Scripts are not executed automatically. A reviewed `hooks/pre.yml` or
`hooks/post.yml` must invoke a local script explicitly:

```yaml
---
- name: Run a reviewed one-time installer
  ansible.builtin.script:
    cmd: "{{ machstrap_profile_root }}/scripts/setup.sh"
    creates: ~/.example-installed
```

Remote script URLs are intentionally unsupported.
