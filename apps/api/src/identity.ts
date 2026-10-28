// The bot's identity, written once. GET / and GET /health answer with
// API_NAME, so a deploy's smoke, an operator's curl and the bootstrap's probe
// all see which bot answered. The Orun bootstrap that creates a product
// rewrites it to that product's name, so keep it literal and on one line.
export const API_NAME = "AI SDK Slackbot"
