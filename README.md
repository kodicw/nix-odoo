# nix-odoo

Declarative Nix library helpers and Nix modules for packaging and configuring Odoo ERP addon suites and dynamic website pages.

## Features

- **`mkOdooAddon`**: Compiles an Odoo website addon on-the-fly from dynamic QWeb page layouts. Performs Nix evaluation-time assertions and sandbox-level XML syntax validation via `xmllint`.
- **`buildOdooAddon`**: A generic builder for standard directory-based Odoo addons that automatically runs manifest syntax checks and `xmllint` validation on all views in the sandbox.
- **`evalOdoo`**: Decoupled module configuration options mapping to Odoo stack layouts.
- **Nix Module**: Schema options for setting up Odoo workers, proxy parameters, and dynamic custom page attributes.

## Usage

Add this flake as an input to your project:

```nix
inputs.nix-odoo.url = "github:kodicw/nix-odoo";
```

Then load the library:

```nix
odooLib = nix-odoo.lib { inherit pkgs; };
```
