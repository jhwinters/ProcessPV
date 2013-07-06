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
dcvolts     = false
deductwatts = 0
interval    = 0
listoutages = false
senddata    = false
shortoutput = false
systemid    = nil
systemkey   = nil
verbose     = false

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

opts.on("--dcvolts", "Process DC voltage instead of AC voltage") do
  dcvolts = true
end

opts.on("-i", "--id ID", "Specify the pvoutput.org system id") do |id|
  systemid  = id
end

opts.on("--interval INTERVAL", "Explicitly specify the interval (in minutes) between readings.") do |specifiedinterval|
  interval = specifiedinterval.to_i
end

opts.on("-o", "--outages", "List outages from the file(s).") do
  listoutages = true
end

opts.on("-v", "--verbose", "Be more verbose about what is found.") do
  verbose = true
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
    if rounded_min == 60
      sprintf("%02d:%02d", hour + 1, 0)
    else
      sprintf("%02d:%02d", hour, rounded_min)
    end
  end

end

class Fixnum
  def fw_str(width)
    sprintf("%#{width}d", self)
  end
end

class Reading

  attr_reader :time, :powernow, :voltagenow, :rawpower

  def initialize(row, deductwatts, dcvolts)
    @time = Time.parse(row[0])
    @rawpower   = row[5].to_i
    if @rawpower > deductwatts
      @powernow   = @rawpower - deductwatts
    else
      @powernow   = 0
    end
    if dcvolts
      @voltagenow = row[10].to_i
    else
      @voltagenow = row[7].to_i
    end
  end

  def to_s
    "Time: #{@time} Power: #{@powernow}"
  end

  def <=>(other)
    self.powernow <=> other.powernow
  end

end

class Outage
  attr_reader :time, :before, :after

  def initialize(time, before, after)
    @time   = time
    @before = before
    @after  = after
  end
end

class ReadingSet < Array

  attr_reader :outages, :apparent_interval

  def initialize(deductwatts, interval, dcvolts)
    @outages      = Array.new
    @outage_time  = nil
    @in_outage    = true
    @dcvolts      = dcvolts
    @deductwatts  = deductwatts
    @consecutivegoodreadings = 0
    @apparent_interval = interval
    @filename = ""
    super()
  end

  def add_reading(row)
    note_reading = false
    if row[5] == "overflow"
      if !@in_outage
        @in_outage = true
        @outage_time = Time.parse(row[0])
      end
      @consecutivegoodreadings = 0
    else
      reading = Reading.new(row, @deductwatts, @dcvolts)
      if @in_outage
        @in_outage = false
        #
        #  If @outage_time is set then this outage had a start time.
        #  If not, then this is our first good reading of the day
        #  and it doesn't count as an outage at all.
        #
        if @outage_time
          @outages << Outage.new(@outage_time, self.last, reading)
        end
      end
      self << reading
      @consecutivegoodreadings += 1
      if @consecutivegoodreadings >= 10 &&
         @apparent_interval == 0
        calculate_apparent_interval
      end
    end
  end

  def max_power
    self.max.powernow
  end

  def min_power
    self.min.powernow
  end

  #
  #  Calculate and return the mean voltage from all our readings.
  #
  def mean_voltage
#    self.inject(0.0){|acc, reading| acc + reading.voltagenow} / self.size
    sum, count = voltage_sum_and_count
    sum / count
  end

  def voltage_sum_and_count
    [self.inject(0.0){|acc, reading| acc + reading.voltagenow}, self.size]
  end

  #
  #  Calculate the apparent interval, in minutes, between our readings.
  #  Only called once we have 10 consecutive good readings.  We use the
  #  last 10 readings in our array.
  #
  def total_energy
    #
    #  We can't get an accurate figure.  We could attempt to use the
    #  trapezium rule, but for now I'm just taking the sum of the areas
    #  of a whole lot of rectangles.
    #
#    puts "Apparent interval = #{@apparent_interval}"
    sum_readings = self.inject(0) {|sum, reading|
                                   sum + reading.powernow}
#    puts "Sum of readings = #{sum_readings}"
    (sum_readings * @apparent_interval) / 60
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
    @filename = filename
    # For chaining
    self
  end

  def self.read_csv_file(filename, deductwatts, interval, dcvolts)
    ReadingSet.new(deductwatts, interval, dcvolts).read_csv_file(filename)
  end

  private

  def calculate_apparent_interval
    if self.size >= 10
      deltas = Array.new
      data = self[-10,10]
      0.upto(8) do |index|
        deltas[index] = data[index + 1].time - data[index].time
      end
      total = deltas.inject(:+)
      mean = (total / 9).to_i
      #
      #  Round to the nearest minute.
      #
      @apparent_interval = (mean + 30) / 60
    end
  end

end

if shortoutput
  puts "Date     Start    End      Max    At       Readings Total     MeanV Outages"
end
voltage_sum = 0.0
voltage_count = 0
rest.each do |filename|
  if verbose
    puts "Processing #{filename}"
  end
  readings = ReadingSet.read_csv_file(filename, deductwatts, interval, dcvolts)
  if readings.size > 0
    if listoutages
      if readings.outages.size > 0
        readings.outages.each do |outage|
          if verbose
            puts "Outage at #{outage.time.hhmmss}"
            puts "Before: voltage #{outage.before.voltagenow}, wattage #{outage.before.powernow}"
            puts "After : voltage #{outage.after.voltagenow}, wattage #{outage.after.powernow}"
          else
            puts outage.time.hhmmss
          end
        end
      else
        unless bequiet
          puts "No outages."
        end
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
               } Wh  #{
                 sprintf("%.1f", readings.mean_voltage)
               } #{
                 readings.outages.size
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
        puts "Outages       : #{readings.outages.size}"
      end
    end
    sum,count = readings.voltage_sum_and_count
    voltage_sum   += sum
    voltage_count += count
  else
    puts "#{filename} empty." unless bequiet
  end
end
if voltage_count > 0 && shortoutput
  puts "Overal mean voltage = #{sprintf("%.2f", voltage_sum / voltage_count)}"
end
