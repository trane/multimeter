require_relative '../spec_helper'


module Multimeter
  describe Http do
    let :registry do
      r = double(:registry)
      r.extend(Http)
      r
    end

    context 'when handling requests' do
      def extract_app
        barrier = java.util.concurrent.Semaphore.new(0)
        app, options = nil, nil
        rack_handler = double(:rack_handler)
        rack_handler.stub(:run) do |a, o|
          app, options = a, o
          barrier.release
        end
        registry.http!(rack_handler)
        barrier.try_acquire(5, java.util.concurrent.TimeUnit::SECONDS).should_not be_false
        [app, options]
      end

      before do
        registry.stub(:to_h).and_return({'hello' => 'world'})
      end

      it 'responds with a JSON document created from calling #to_h on the registry' do
        app, options = extract_app
        status, headers, body = app.call({'QUERY_STRING' => ''})
        body.join("\n").should == '{"hello":"world"}'
      end

      it 'responds with application/json' do
        app, options = extract_app
        status, headers, body = app.call({'QUERY_STRING' => ''})
        headers['Content-Type'].should == 'application/json'
      end

      it 'responds with a JSON document wrapped in a function call when the callback parameter is given' do
        app, options = extract_app
        status, headers, body = app.call({'QUERY_STRING' => 'callback=the_cbk'})
        body.join("\n").should == 'the_cbk({"hello":"world"});'
      end

      it 'responds with application/javascript for JSONP request' do
        app, options = extract_app
        status, headers, body = app.call({'QUERY_STRING' => 'callback=the_cbk'})
        headers['Content-Type'].should == 'application/javascript'
      end

      it 'responds with error 400 if the callback contains invalid chars' do
        app, options = extract_app
        status, headers, body = app.call({'QUERY_STRING' => 'callback=apa*&^%$'})
        status.should == 400
      end

      it 'responds with error 500 if an exception is thrown in the request handling' do
        registry.stub(:to_h).and_raise('blurgh')
        app, options = extract_app
        status, headers, body = app.call({'QUERY_STRING' => 'callback=apa*&^%$'})
        status.should == 500
      end
    end
  end
end
