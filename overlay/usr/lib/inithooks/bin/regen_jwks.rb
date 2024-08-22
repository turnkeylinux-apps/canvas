# Rails script to regenerate LTI JWK tokens
#
# This script is run by regen_jwks via rails runner

keys = ["jwk-past.json", "jwk-present.json", "jwk-future.json"]

rsa_key = OpenSSL::PKey::RSA.generate(2048)

for key in keys do
  jwk = rsa_key.public_key.to_jwk(kid: Time.now.utc.iso8601).to_json
  puts "#{key} #{jwk}"
end
