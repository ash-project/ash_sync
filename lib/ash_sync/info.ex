defmodule AshSync.Info do
  use Spark.InfoGenerator, extension: AshSync, sections: [:sync]
end
