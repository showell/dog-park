# Deploying Dog Park to its own droplet

One droplet, booted from a custom image this repo builds, with no Linux on
it, as lynrummy.com's metal droplet is (zig-metal-unikernel's README, "Where
lynrummy.com runs" and "A deploy"). Prod's Caddy holds HTTPS for
`dogpark.lynrummy.com` and forwards to it over the private network. Prod's
addresses are in zig-metal-unikernel's `DEPLOY.md`, "The machines"; call its
public one `<prod>` below.

**One disk, no volume.** The image holds the kernel, the page (`solo/`), the
admin key and the machine's settings, and Dog Park writes its accounts and
games onto that same disk. There is no data volume and no recovery-console
step. **A new image starts Dog Park empty**: every account, game and cookie
goes with the old one (accepted for now, Steve 2026-10-15).

Steps marked **(box-verified)** are checked on the box by the build; the
rest are clicks or commands on DigitalOcean or prod, which the box cannot
check.

## The first deploy

1. **Build the image** (box-verified). With all three trees compiled into
   it clean (this one, ../zig-metal-unikernel and ../zig-webbox), and
   pushed (nothing checks that):

       cd ~/showell_repos/dog-park
       zig build metal-gate            # the QEMU gate (README)
       node droplet/image.mjs

   It builds `zig-out/bin/dogpark.elf`, writes
   `~/dogpark-images/dogpark-<commit>.img` (`<commit>` is 12 characters)
   and `.img.gz` beside it (1 GiB raw; under 2 MiB gzipped when last
   measured), prints both sha256s, and then boots the image on QEMU laid out
   as a droplet (`droplet/rehearse.mjs`): it must end `ready to deploy`.
   - **It refuses** on uncommitted changes in any of the three trees
     (`DOGPARK_IMAGE_DIRTY=1` builds anyway, and says so: an image no
     commit describes), and without `droplet/trusted-proxy` (prod's
     private address).
   - **The first time,** it makes `~/.dogpark_admin_key` (mode 600; it
     never prints it), and builds zig-webbox's `shale-sign` to make Dog
     Park's Shale key pair, `~/.shale_signing_key.dogpark.lynrummy.com`.

2. **Serve the .gz to DigitalOcean**, in a terminal on the box:

       cd ~/dogpark-images && python3 -m http.server 9301

   The URL is `http://<the dev box's public address>:9301/dogpark-<commit>.img.gz` (the
   name step 1 printed; the address is `curl -s https://ifconfig.me` on the box). Leave it running until step 3 says the import is
   done, then Ctrl-C it.

3. **Import it as a custom image.** DigitalOcean: Backups & Snapshots →
   Custom Images → Import via URL.
   - URL: the one from step 2.
   - Name: `dogpark-<commit>`.
   - Distribution: **Unknown** (there is no Linux on it).
   - Region: **prod's**, nyc2 (lynrummy.com's metal droplet is there too),
     so the private network reaches it.

   Wait until the image says it is ready (a few minutes).

4. **Create the droplet.** Droplets → Create Droplet:
   - Region: nyc2. VPC: **the one prod is in** (nyc2's default, unless prod
     is in another).
   - Image: Custom images → `dogpark-<commit>`.
   - Size: the cheapest Basic (512 MB), or the cheapest Premium when the
     region offers no Basic; the image runs on either. The rehearsal boots
     it with 512 MB.
   - Authentication: whatever the form insists on; nothing on the machine
     reads it. No backups, no monitoring (there is no Linux for the agent).
   - Hostname: `dogpark`.

5. **Watch it boot**: the droplet's Access → Launch Recovery Console shows
   the kernel's screen. The lines that matter:

       no volume attached
       Dog Park's data: the boot disk
       network: the private card
       listening on port 80

   `stopped` instead means it refused something, and says what just above.

6. **Read its private address**: the droplet's page, "Private IP" (a
   `10.x.x.x`). Call it `<dogpark>` below. On prod, it answers:

       curl -s http://<dogpark>/ | grep -c 'Begin Game'     # 1

7. **DNS**: an A record `dogpark.lynrummy.com` → `<prod>` (prod's public
   address, not the new droplet), wherever lynrummy.com's records live (DigitalOcean →
   Networking → Domains, if that is where they are).

8. **Caddy on prod.** The site block is
   [`droplet/dogpark.lynrummy.com.caddy`](droplet/dogpark.lynrummy.com.caddy);
   prod's Caddyfile already imports `/etc/caddy/sites/*.caddy`, and defines
   the `access_log` snippet the block imports (angry-gopher's
   `deploy/Caddyfile`, metal-vmm QUEUE 221; it must be installed first). On
   prod:

       sudoedit /etc/caddy/sites/dogpark.lynrummy.com.caddy    # paste the file; <dogpark-private-address> → <dogpark>
       sudo install -o caddy -g caddy -m 640 /dev/null /var/log/caddy/dogpark-access.log
       sudo caddy validate --config /etc/caddy/Caddyfile
       sudo systemctl reload caddy

   The block, with the address filled in:

       dogpark.lynrummy.com {
       	encode gzip
       	request_body {
       		max_size 1MiB
       	}
       	header {
       		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
       		X-Content-Type-Options "nosniff"
       		Referrer-Policy "strict-origin-when-cross-origin"
       		X-Frame-Options "SAMEORIGIN"
       	}
       	import access_log dogpark
       	reverse_proxy <dogpark>:80
       }

   Caddy gets the certificate once step 7's record resolves. The access
   log must exist and be Caddy's before `validate`: validate runs as root
   and would make it root's, and the reload then fails on "permission
   denied" (Caddy keeps its old config, so nothing goes down).

9. **Smoke test**, from the box:

       curl -s https://dogpark.lynrummy.com/ | grep -c 'Begin Game'                    # 1
       curl -s -o /dev/null -w '%{http_code}\n' \
         -H "Authorization: Bearer $(cat ~/.dogpark_admin_key)" \
         https://dogpark.lynrummy.com/admin/game                                       # 200
       curl -s -o /dev/null -w '%{http_code}\n' https://dogpark.lynrummy.com/admin/game  # 403

   Then in a browser: Begin Game, and play. `/admin` takes the same key
   (`cat ~/.dogpark_admin_key` on the box) for the admin pages.

10. **A monitoring script** (optional), from the box. The image carries Dog
    Park's own Shale public key (`auth/shale.conf`, made by step 1 from
    `~/.shale_signing_key.dogpark.lynrummy.com`, never lynrummy's key):

        cd ~/showell_repos/dog-park/tools/shale
        (cd ~/showell_repos/zig-webbox && zig build shale-sign -- background $OLDPWD/accounts.shale dogpark.lynrummy.com)
        curl -sS -H "Authorization: Bearer $(cat ~/.dogpark_admin_key)" --data-binary @accounts.shale.<sequence>.req https://dogpark.lynrummy.com/admin/script
        curl -sS -H "Authorization: Bearer $(cat ~/.dogpark_admin_key)" https://dogpark.lynrummy.com/admin/script

    The last line shows the run and what it printed (README, "Running a
    script").

## A new release

1. Steps 1-3 again.
2. On the **`dogpark`** droplet: Destroy → **Restore base image**, from
   the new Dog Park image. Check the droplet's and the image's names
   first: lynrummy.com's image restored on this droplet stops at "no volume
   attached", and the restore has already wiped Dog Park's disk.
3. Step 9's smoke test again, and the commit:

       curl -s https://dogpark.lynrummy.com/version

   Its `commit` (git's short form) must begin the 12-character commit in
   the image's name. An image built before `/version` existed answers 404;
   check the image's name on the droplet's page instead.

The private address stays, so Caddy needs nothing. Accounts and games start
over.

## The way back

- **A bad release:** restore the droplet's base image from the previous
  release (Custom Images keeps every imported one), as in "A new release",
  step 2. Accounts and games start over again.
- **No Dog Park at all:** destroy the droplet. Nothing else depends on it:
  remove `/etc/caddy/sites/dogpark.lynrummy.com.caddy` on prod and reload
  Caddy, delete the DNS record, and delete the custom images. lynrummy.com
  is not touched by any of it.

## What the image holds, and why

- **Partition 1**: `dogpark.elf`, the kernel (zig-metal-unikernel's
  `droplet/app_image.py`, any application's image builder, lays the disk out).
- **Partition 2**, FAT16, 1 GiB: `solo/`, `auth/_admin_key`, and
  `zig-metal-unikernel.conf`:

      idle_timeout_ms = 10000
      card = private
      trusted_proxy = <prod's private address>

  `card = private`: nothing on the internet reaches it, only the private
  network, prod among it. `trusted_proxy` is prod's private address, from
  `droplet/trusted-proxy` (`cat` it; the kernel's own copy says the same): Caddy's
  `X-Forwarded-For` is believed from it alone. With no `volume` line and no
  volume attached, the kernel keeps `data/` and `auth/` on this partition
  (its `probe/gopher.zig`, "the disks"; its README says what each conf key
  does). The session secret is made there at the first start.
