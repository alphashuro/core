# have rack raise an exception if the request goes longer than 20s
Rails.application.config.middleware.insert_before Rack::Runtime, Rack::Timeout, service_timeout: ENV['RACK_TIMEOUT'].to_i if ENV['RACK_TIMEOUT']

# set 10 second timeout on postgres queries
if ENV['POSTGRES_TIMEOUT']
  ApplicationRecord.connection.execute("set statement_timeout TO #{ENV['POSTGRES_TIMEOUT'].to_i}s;")
end
