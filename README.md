# Omega-Mods – ComboPathFix

**Category:** Gameplay (script only)  
**Game:** Farming Simulator 25

Fixes `<combination>` path resolution so you can reference XMLs from other mods:

- `$moddir<OtherModName>$/path/to/file.xml`
- `moddir<OtherModName>$/path/to/file.xml` (accepted even without the leading `$`)

Works during vehicle XML load and at Store linking time. Also installs an umbrella hook
on `Utils.getFilename` to transparently resolve extended tokens.

## How to use
In your implement's XML:

```xml
<combinations>
  <combination xmlFilename="$moddirFS25_tony10900TTRX$/tony10900TTR.xml"/>
</combinations>
```

If the target mod or file is missing, the game will log a readable warning without crashing.

## MP & Savegame

* No custom save data. Deterministic and MP-safe.
* Client-side only; server should also run the mod for consistency.

## License

MIT – see `LICENSE.txt`.
