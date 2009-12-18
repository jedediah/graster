begin
  require 'jeweler'
  Jeweler::Tasks.new do |s|
    s.name = "graster"
    s.description = s.summary = "G Raster!"
    s.email = "joshbuddy@gmail.com"
    s.homepage = "http://github.com/joshbuddy/graster"
    s.authors = ["Jedediah Smith", "Joshua Hull"]
    s.files = FileList["[A-Z]*", "{lib,bin}/**/*"]
    s.add_dependency 'rmagick'
    s.rubyforge_project = 'graster'
  end
  Jeweler::GemcutterTasks.new
rescue LoadError
  puts "Jeweler not available. Install it with: sudo gem install technicalpickles-jeweler -s http://gems.github.com"
end

require 'rake/rdoctask'
desc "Generate documentation"
Rake::RDocTask.new do |rd|
  rd.main = "README.rdoc"
  rd.rdoc_files.include("README.rdoc", "lib/**/*.rb")
  rd.rdoc_dir = 'rdoc'
end
