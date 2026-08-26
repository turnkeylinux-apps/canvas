// Passenger cannot pass the --import option used by the official npm start
// command. Load instrumentation before importing the application module so
// dotenv and error instrumentation are initialized before dependency wiring.
await import("./instrument.js");
await import("./app.js");
