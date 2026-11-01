# XRIXUID batch processing benchmark

A bounded, rate-limited and deduplicated job executor. It accepts **only an explicitly authorized data-source adapter** and does not collect Facebook user records or bypass rate limits.

```bash
node benchmark.mjs 5000 200
```

This test uses generated mock data. It measures local queue overhead only. Passing it **does not mean** 5000 valid Facebook profiles can be retrieved within 10 minutes without tokens or cookies. The live deployment and the original scraper are not changed by this GitHub branch.

For real integrations, use a source granting collection permission, keep its rate cap, respect server retry delays, and never log or submit user-supplied passwords.
