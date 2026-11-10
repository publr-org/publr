# CLI: `device`

Agents and tools acting for an account, signed in by link. How devices work and what each
scope allows is in [Authentication: Devices](../auth.md#devices); `publr login` runs the
device's side for you ([CLI: A Publr elsewhere](../cli.md#a-publr-elsewhere)). Back to the
[CLI reference](../cli.md).

## `start`

Anyone. A device asks to act for someone: `--name` is what they will see, `--scope` what
it asks to do at most (`production` by default). Answers the device code (kept by the device, never
shown), the user code and `approve_path`, the page on this site where the person approves
it. The request lapses after ten minutes.

```
$ publr device start --name "An agent on Ada's laptop"
{ "device_code": "9f2c…", "user_code": "WXYZ-BCDF",
  "approve_path": "/admin/settings/devices/approve?code=WXYZ-BCDF", … }
```

## `poll`

Anyone holding the device code. `pending`, `approved`, `denied` or `expired`. A read: it
writes nothing, so asking every few seconds costs nothing.

## `claim`

Anyone holding the device code, once it is approved: the token, given once. The request
is then used up. It also takes the code `offer` answered, with `--name` for what the
device is called.

## `offer`

A signed-in person, never a device. A sign-in for one of their own computers, approved as
it is made (`--scope`, `publish` by default): answers a one-time code that `claim` takes
within ten minutes. The admin's Overview puts it in the command that sets up an agent's
computer, `curl -fsSL <site>/api/agent/<code> | sh`, which installs the publr command,
signs the computer in (`publr login <site> --claim <code>`) and installs the skill.

## `authorize`, `exchange`

Anyone; the OAuth addresses call them for an MCP client
([Authentication: MCP clients](../auth.md#mcp-clients)). `authorize` keeps a client's
request (`--client_id`, `--redirect_uri`, `--code_challenge`, `--state`, `--scope`) and
answers the user code and its `approve_path`. `exchange` trades the code the client was
sent back with, and its PKCE verifier, for the device's token, once.

## `request`, `approve`, `deny`

A signed-in person, never a device. `request` shows what a waiting device asks for, by
the user code; `approve` lets it act for the caller's account with `--scope` (no more than
it asked); `deny` turns it away. The admin's approve page calls these. For an MCP client,
`request` answers its return address, and `approve` and `deny` answer where to send the
person: back to the client, with its code or saying it was refused.

```
$ publr --as ada@example.com device approve --code WXYZ-BCDF --scope production
{ "approved": true }
```

## `list`

Any signed-in account, or a device: the devices acting for the account, newest first,
with `current` on the one asking. `--all true` lists every account's, for administrators.

## `revoke`

A person revokes their own devices, an administrator anyone's; a device only itself
(`publr logout`). It stops working at once; what it changed stays.

## `redeem`

Anyone: a device's token for the account a sign-on token from the trusted issuer names
(`sign_on configure`), the sign-on token used up. How a Publr Cloud dashboard connects a
chat app to a project.
