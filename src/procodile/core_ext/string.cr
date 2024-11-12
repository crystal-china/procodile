class String
  def color(color : Int32?) : String
    "\e[#{color}m#{self}\e[0m"
  end
end
