// Passenger cannot pass the --import option used by the official npm start
// command. Ordered static imports load instrumentation before the application
// while keeping the graph synchronous for Passenger's CommonJS node-loader.
import "./instrument.js";
import "./app.js";
