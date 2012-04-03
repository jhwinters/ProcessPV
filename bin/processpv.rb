#!/usr/bin/ruby

# Copyright (C) 2012, John Winters

# This program is free software; you can redistribute it and/or modify
# it under the terms of version 2 of the GNU General Public License as
# published by the Free Software Foundation.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

require 'csv'
require 'optparse'
require 'time'
require 'net/http'
require 'uri'

bequiet     = false
datadate    = nil
deductwatts = 0
listoutages = false
senddata    = false
shortoutput = false
systemid    = nil
systemkey   = nil

opts = OptionParser.new
opts.banner = "Usage: processpv [file]"

opts.on("-h", "--help", "Show this message") do
  puts opts
  exit
end

opts.on("-d", "--date YYYYMMDD", "Specify the effective date for the data") do |date|
  datadate  = date
end

opts.on("--deduct WATTS", "Reduce each individual reading by WATTS") do |watts|
  deductwatts = watts.to_i
end

opts.on("-i", "--id ID", "Specify the pvoutput.org system id") do |id|
  systemid  = id
end

opts.on("-o", "--outages", "List outages from the file(s).") do
  listoutages = true
end

opts.on("-k", "--key KEY", "Specify the pvoutput.org system key") do |key|
  systemkey = key
end

opts.on("-q", "--quiet", "Be quiet - especially for use in cron jobs") do
  bequiet = true
end

opts.on("-s", "--send", "Send data to pvoutput.org") do
  senddata = true
end

opts.on("--short", "Produce short (just one line) output for each file.") do
  shortoutput = true
end

begin
  rest = opts.parse($*)
rescue StandardError => error
  puts error
  exit
end

class Time
  def hhmmss
    self.strftime("%H:%M:%S")
  end

  def hhmm
    self.strftime("%H:%M")
  end

  #
  #  Pvoutput.org wants the time in hours and minutes but can manage
  #  only multiples of 5 minutes.
  #
  def hhmm_nearest5
    rounded_min = ((min + 2) / 5) * 5
    sprintf("%02d:%02d", hour, rounded_min)
  end

end

class Fixnum
  def fw_str(width)
    sprintf("%#{width}d", self)
  end
end

class Reading

  attr_reader :time, :powernow, :voltagenow, :rawpower

  def initialize(row, deductwatts)
    @time = Time.parse(row[0])
    @rawpower   = row[5].to_i
    if @rawpower > deductwatts
      @powernow   = @rawpower - deductwatts
    else
      @powernow   = 0
    end
    @voltagenow = row[7].to_i
  end

  def to_s
    "Time: #{@time} Power: #{@powernow}"
  end

  def <=>(other)
    self.powernow <=> other.powernow
  end

end

class ReadingSet < Array

  attr_reader :outage_count, :outage_times

  def initialize(deductwatts)
    # Don't count warm-up as an outage.
    @outage_count = -1
    @outage_times = Array.new
    @in_outage    = true
    @deductwatts  = deductwatts
    super()
  end

  def add_reading(row)
    if row[5] == "overflow"
      if !@in_outage
        @in_outage = true
        @outage_times << Time.parse(row[0])
      end
    else
      if @in_outage
        @in_outage = false
        @outage_count += 1
      end
      self << Reading.new(row, @deductwatts)
    end
  end

  def max_power
    self.max.powernow
  end

  def min_power
    self.min.powernow
  end

  #
  #  Calculate the apparent interval, in minutes, between our readings.
  #  Requires at least 10 readings
  #
  def apparent_interval
    if self.size < 10
      0
    else
      deltas = Array.new
      0.upto(8) do |index|
        deltas[index] = self[index + 1].time - self[index].time
      end
      total = deltas.inject(:+)
      mean = (total / 9).to_i
      #
      #  Round to the nearest minute.
      #
      (mean + 30) / 60
    end
  end

  def total_energy
    #
    #  We can't get an accurate figure.  We could attempt to use the
    #  trapezium rule, but for now I'm just taking the sum of the areas
    #  of a whole lot of rectangles.
    #
#    puts "Apparent interval = #{apparent_interval}"
    sum_readings = self.inject(0) {|sum, reading|
                                   sum + reading.powernow}
#    puts "Sum of readings = #{sum_readings}"
    (sum_readings * apparent_interval) / 60
  end

  def do_send(url, systemid, systemkey, data)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)

    request = Net::HTTP::Post.new(uri.request_uri)
    request["X-Pvoutput-Apikey"]   = systemkey
    request["X-Pvoutput-SystemId"] = systemid
    request.set_form_data(data)
    response = http.request(request)
    if response.code != "200"
      puts response.body
    end
  end

  def send_to_pvoutput(systemid, systemkey, datadate)
    unless @in_outage
      data = {"d"  => datadate,
              "t"  => self.last.time.hhmm,
              "v1" => self.total_energy.to_s,
              "v2" => self.last.powernow.to_s,
              "v6" => self.last.voltagenow.to_s}
      do_send("http://pvoutput.org/service/r2/addstatus.jsp",
              systemid,
              systemkey,
              data)
    end
    data = {"d"  => datadate,
            "g"  => self.total_energy.to_s,
            "pp" => self.max_power.to_s,
            "pt" => self.max.time.hhmm_nearest5,
            "cd" => "Not Sure"}
    do_send("http://pvoutput.org/service/r2/addoutput.jsp",
            systemid,
            systemkey,
            data)
  end
                       
  def read_csv_file(filename)
    #
    #  The workings of CSV changed in Ruby 1.9, so we need two different
    #  ways of calling it.
    #
    if RUBY_VERSION =~ /1.8/
      CSV.open(filename, "r") do |row|
        self.add_reading(row)
      end
    else
      # Assume we are using a later version
      CSV.foreach(filename, "r") do |row|
        self.add_reading(row)
      end
    end
    # For chaining
    self
  end

  def self.read_csv_file(filename, deductwatts)
    ReadingSet.new(deductwatts).read_csv_file(filename)
  end

end

if shortoutput
  puts "Date     Start    End      Max    At       Readings Total    Outages"
end
rest.each do |filename|
  readings = ReadingSet.read_csv_file(filename, deductwatts)
  if readings.size > 0
    if listoutages
      if readings.outage_count > 0
        readings.outage_times.each do |ot|
          puts ot.hhmmss
        end
      else
        puts "No outages."
      end
    elsif senddata
      if systemid && systemkey && datadate
        readings.send_to_pvoutput(systemid, systemkey, datadate)
      else
        puts "Must specify a date, system id and key in order to send to pvoutput.org"
      end
    else
      if shortoutput
        puts "#{
                 File.basename(filename, '.*')
               } #{
                 readings.first.time.hhmmss
               } #{
                 readings.last.time.hhmmss
               } #{
                 readings.max_power.fw_str(4)
               } W #{
                 readings.max.time.hhmmss
               } #{
                 readings.size.fw_str(3)
               }      #{
                 readings.total_energy.fw_str(5)
               } Wh #{
                 readings.outage_count
               }"
      else
        puts "Processed     : #{filename}"
        puts "Maximum power : #{
                readings.max_power
              } W at #{
                readings.max.time.hhmmss
              }"
        puts "Minimum power : #{
                readings.min_power
              } W at #{
                readings.min.time.hhmmss
              }"
        puts "Total energy  : #{readings.total_energy} Wh"
        puts "First reading : #{readings.first.time.hhmmss} (#{readings.first.powernow} W)"
        puts "Last reading  : #{readings.last.time.hhmmss} (#{readings.last.powernow} W)"
        puts "Total readings: #{readings.size}"
        puts "Outages       : #{readings.outage_count}"
      end
    end
  else
    puts "#{filename} empty." unless bequiet
  end
end
